#!/bin/bash

set -e

SPIDER_DIR="/app/GSB-Dogfood-VidSpider/douyin_spider/douyin_spider"

# 修复 douyin.py
cat > "${SPIDER_DIR}/spiders/douyin.py" << 'EOF'
import scrapy
import re
import requests


class DouyinSpider(scrapy.Spider):
    name = "douyin"
    allowed_domains = ["douyin.com", "iesdouyin.com", "zjcdn.com", "byteeffecttos.com", "localhost", "127.0.0.1"]
    start_urls = []

    custom_settings = {
        'USER_AGENT': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'DEFAULT_REQUEST_HEADERS': {
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.8,en-US;q=0.5,en;q=0.3',
            'Referer': 'https://www.douyin.com/',
        },
        'DOWNLOADER_MIDDLEWARES': {
            'douyin_spider.middlewares.PlaywrightMiddleware': 543,
        },
        'DOWNLOAD_TIMEOUT': 120,
    }

    def __init__(self, url=None, *args, **kwargs):
        super(DouyinSpider, self).__init__(*args, **kwargs)
        if url:
            self.start_urls = [url]

    def parse(self, response):
        video_urls = response.meta.get('video_urls', [])

        self.logger.debug(f'Response status: {response.status}, content length: {len(response.body)} bytes')

        if not video_urls:
            self.logger.warning('No video URLs captured from network, trying regex extraction...')

            patterns = [
                r'https?://[^\s"\'<>]+\.mp4[^\s"\'<>]*',
                r'https?://[^\s"\'<>]+/video/[^\s"\'<>]*',
            ]

            for pattern in patterns:
                matches = re.findall(pattern, response.text)
                for match in matches:
                    if 'blob:' not in match and 'byted-static' not in match:
                        import urllib.parse
                        cleaned_url = urllib.parse.unquote(match)
                        cleaned_url = re.sub(r'[\\\'\"\s]+$', '', cleaned_url)
                        cleaned_url = cleaned_url.rstrip('\\/')
                        if cleaned_url not in video_urls:
                            video_urls.append(cleaned_url)
                            self.logger.debug(f'Regex extracted URL: {cleaned_url[:80]}...')

        if not video_urls:
            self.logger.warning('Trying to extract video from page JSON data...')
            try:
                import json
                json_patterns = [
                    r'window\.__INIT_STATE__\s*=\s*({.*?});',
                    r'window\._SSR_HYDRATED_DATA\s*=\s*({.*?})',
                    r'window\.__NUXT__\s*=\s*\((.*?)\);',
                    r'var\s+data\s*=\s*({.*?});',
                    r'<script[^>]*>\s*({.*?})\s*</script>',
                    r'<script[^>]*type="application/json"[^>]*>\s*({.*?})\s*</script>',
                    r'id="RENDER_DATA"[^>]*>\s*({.*?})\s*</script>',
                ]
                for pattern in json_patterns:
                    matches = re.search(pattern, response.text, re.DOTALL)
                    if matches:
                        try:
                            json_str = matches.group(1)
                            data = json.loads(json_str)

                            def find_video_urls(obj):
                                urls = []
                                if isinstance(obj, dict):
                                    for k, v in obj.items():
                                        if k in ['play_addr', 'video_url', 'src', 'url']:
                                            if isinstance(v, dict) and 'url_list' in v:
                                                urls.extend(v['url_list'])
                                            elif isinstance(v, str) and v.startswith('http'):
                                                urls.append(v)
                                        else:
                                            urls.extend(find_video_urls(v))
                                elif isinstance(obj, list):
                                    for item in obj:
                                        urls.extend(find_video_urls(item))
                                return urls

                            found = find_video_urls(data)
                            for url in found:
                                if url and url.startswith('http'):
                                    import urllib.parse
                                    cleaned_url = urllib.parse.unquote(url)
                                    cleaned_url = re.sub(r'[\\\'\"\s]+$', '', cleaned_url)
                                    cleaned_url = cleaned_url.rstrip('\\/')
                                    if cleaned_url not in video_urls:
                                        video_urls.append(cleaned_url)
                        except:
                            pass
            except Exception as e:
                self.logger.debug(f'JSON extraction failed: {str(e)}')

        self.logger.info(f'Total video URLs found: {len(video_urls)}')

        valid_videos = []
        import urllib.parse
        for video_url in video_urls:
            cleaned_url = urllib.parse.unquote(video_url)
            cleaned_url = re.sub(r'[\\\'\"\s]+$', '', cleaned_url)
            cleaned_url = cleaned_url.rstrip('\\/')
            video_url = cleaned_url
            try:
                head = requests.head(
                    video_url,
                    timeout=10,
                    headers={
                        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
                        'Referer': 'https://www.douyin.com/',
                        'Accept': '*/*',
                    },
                    allow_redirects=True
                )

                content_type = head.headers.get('content-type', '')
                content_length = int(head.headers.get('content-length', 0))

                is_video = False
                if 'video/' in content_type.lower():
                    is_video = True
                elif 'application/octet-stream' in content_type.lower() and content_length > 10000:
                    is_video = True
                elif content_length > 100000:
                    is_video = True

                if is_video:
                    valid_videos.append((video_url, content_length))
                    self.logger.info(f'Valid video: {content_length/1024/1024:.2f} MB - {video_url[:100]}...')

            except Exception as e:
                self.logger.debug(f'Network error: {str(e)[:50]}')

        if valid_videos:
            valid_videos.sort(key=lambda x: x[1], reverse=True)
            best_url, best_size = valid_videos[0]

            title = 'douyin_video'
            og_title = response.xpath('//meta[@property="og:title"]/@content').get()
            if og_title:
                title = og_title

            self.logger.info(f'Selected best video: {best_size/1024/1024:.2f} MB')

            yield {
                'video_url': best_url,
                'title': title,
                'size_mb': round(best_size / 1024 / 1024, 2),
                'video_urls': [url for url, _ in valid_videos]
            }
        else:
            self.logger.warning('No valid video files found')
            yield {
                'video_url': None,
                'title': 'no_video',
                'size_mb': 0,
                'video_urls': []
            }
EOF

# 修复 pipelines.py
cat > "${SPIDER_DIR}/pipelines.py" << 'EOF'
import os
import requests
from itemadapter import ItemAdapter
from scrapy.exceptions import DropItem


class DouyinVideoDownloadPipeline:
    def __init__(self):
        self.output_dir = os.environ.get(
            'DOUYIN_OUTPUT_DIR',
            '/app/GSB-Dogfood-VidSpider/douyinOutput'
        )

        try:
            os.makedirs(self.output_dir, exist_ok=True)
            os.chmod(self.output_dir, 0o755)
        except OSError:
            pass

    def process_item(self, item, spider):
        adapter = ItemAdapter(item)
        video_url = adapter.get('video_url')
        title = adapter.get('title', 'douyin_video')

        if not video_url:
            raise DropItem("Missing video URL in item")

        title = self.sanitize_filename(title)

        file_path = os.path.join(self.output_dir, f'{title}.mp4')

        counter = 1
        while os.path.exists(file_path):
            file_path = os.path.join(self.output_dir, f'{title}_{counter}.mp4')
            counter += 1

        try:
            spider.logger.info(f'Downloading video from: {video_url}')

            headers = {
                'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
                'Accept': '*/*',
                'Accept-Language': 'en',
                'Referer': 'https://www.douyin.com/',
            }

            response = requests.get(
                video_url,
                stream=True,
                timeout=120,
                headers=headers
            )
            response.raise_for_status()

            with open(file_path, 'wb') as f:
                for chunk in response.iter_content(chunk_size=8192):
                    if chunk:
                        f.write(chunk)

            spider.logger.info(f'Video saved to: {file_path}')
            adapter['file_path'] = file_path

        except Exception as e:
            spider.logger.error(f'Failed to download video: {str(e)}')
            adapter['file_path'] = file_path
            adapter['error'] = str(e)

        return item

    def sanitize_filename(self, filename):
        invalid_chars = '<>:"/\\|?*'
        for char in invalid_chars:
            filename = filename.replace(char, '_')
        filename = filename.strip()
        if len(filename) > 100:
            filename = filename[:100]
        return filename if filename else 'douyin_video'

    def close_spider(self, spider):
        spider.logger.info("Pipeline closed")
EOF

# 修复 settings.py
cat > "${SPIDER_DIR}/settings.py" << 'EOF'
BOT_NAME = "douyin_spider"

SPIDER_MODULES = ["douyin_spider.spiders"]
NEWSPIDER_MODULE = "douyin_spider.spiders"

ADDONS = {}

ROBOTSTXT_OBEY = False

CONCURRENT_REQUESTS_PER_DOMAIN = 1
DOWNLOAD_DELAY = 1

ITEM_PIPELINES = {
    "douyin_spider.pipelines.DouyinVideoDownloadPipeline": 300,
}

FEED_EXPORT_ENCODING = "utf-8"

DOWNLOADER_MIDDLEWARES = {
    'douyin_spider.middlewares.PlaywrightMiddleware': 543,
}

DNS_TIMEOUT = 60

DOWNLOAD_TIMEOUT = 120

RETRY_TIMES = 3

USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
EOF

# 修复 middlewares.py - 移除 FaultyHTTPHandler，修复 PlaywrightMiddleware
cat > "${SPIDER_DIR}/middlewares.py" << 'EOF'
from scrapy import signals
from scrapy.http import HtmlResponse
from playwright.sync_api import sync_playwright
import urllib.parse
import re
import threading
import time


class PlaywrightMiddleware:
    def __init__(self):
        self.playwright = None
        self.browser = None
        self.context = None
        self._initialized = False
        self._init_lock = threading.Lock()

    @classmethod
    def from_crawler(cls, crawler):
        middleware = cls()
        crawler.signals.connect(middleware.spider_opened, signal=signals.spider_opened)
        crawler.signals.connect(middleware.spider_closed, signal=signals.spider_closed)
        return middleware

    def spider_opened(self, spider):
        if spider.name not in ['douyin_playwright', 'douyin']:
            return

        with self._init_lock:
            if self._initialized:
                return

            try:
                spider.logger.info("Initializing Playwright (sync mode)...")
                self.playwright = sync_playwright().start()
                self.browser = self.playwright.chromium.launch(
                    headless=True,
                    args=[
                        '--no-sandbox',
                        '--disable-dev-shm-usage',
                        '--disable-gpu',
                        '--disable-extensions',
                        '--disable-plugins',
                        '--disable-images',
                        '--disable-background-networking',
                        '--disable-background-timer-throttling',
                        '--disable-backgrounding-occluded-windows',
                        '--disable-breakpad',
                        '--disable-client-side-phishing-detection',
                        '--disable-component-extensions-with-background-pages',
                        '--disable-default-apps',
                        '--disable-features=TranslateUI',
                        '--disable-hang-monitor',
                        '--disable-ipc-flooding-protection',
                        '--disable-popup-blocking',
                        '--disable-prompt-on-repost',
                        '--disable-renderer-backgrounding',
                        '--disable-sync',
                        '--force-color-profile=srgb',
                        '--metrics-recording-only',
                        '--no-first-run',
                        '--enable-automation',
                        '--password-store=basic',
                        '--use-mock-keychain',
                    ]
                )
                self.context = self.browser.new_context(
                    user_agent='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                    viewport={'width': 1920, 'height': 1080},
                )
                self._initialized = True
                spider.logger.info("Playwright initialized successfully (sync mode)!")
            except Exception as e:
                spider.logger.error(f"Failed to initialize Playwright: {str(e)}")
                import traceback
                spider.logger.error(f"Traceback: {traceback.format_exc()}")
                raise

    def spider_closed(self, spider):
        if self.context:
            try:
                self.context.close()
            except:
                pass
        if self.browser:
            try:
                self.browser.close()
            except:
                pass
        if self.playwright:
            try:
                self.playwright.stop()
            except:
                pass

    def process_request(self, request, spider):
        if spider.name not in ['douyin_playwright', 'douyin']:
            return None

        if not self._initialized:
            spider.logger.error("Playwright is not initialized! Falling back to normal downloader.")
            return None

        if not self.context:
            spider.logger.error("Playwright context is not available! Falling back to normal downloader.")
            return None

        video_urls = []
        page = None

        try:
            page = self.context.new_page()

            def handle_response(response):
                url = response.url
                spider.logger.debug(f'Network response: {response.status} - {url[:80]}...')
                if '.mp4' in url and 'blob:' not in url and 'byted-static' not in url and 'playvm' not in url:
                    cleaned_url = urllib.parse.unquote(url)
                    cleaned_url = re.sub(r'[\\\'\"\s]+$', '', cleaned_url)
                    cleaned_url = cleaned_url.rstrip('\\/')

                    if cleaned_url not in video_urls:
                        spider.logger.debug(f'Captured video URL: {cleaned_url[:100]}...')
                        video_urls.append(cleaned_url)

                if 'aweme/v1/web/aweme/detail' in url or 'aweme/detail' in url:
                    try:
                        if response.status == 200:
                            content_type = response.headers.get('content-type', '')
                            if 'application/json' in content_type:
                                try:
                                    body = response.json()
                                    if body and 'aweme_detail' in body:
                                        aweme = body['aweme_detail']
                                        if 'video' in aweme and 'play_addr' in aweme['video']:
                                            play_addr = aweme['video']['play_addr']
                                            if 'url_list' in play_addr and play_addr['url_list']:
                                                for video_url in play_addr['url_list']:
                                                    cleaned_url = urllib.parse.unquote(video_url)
                                                    cleaned_url = re.sub(r'[\\\'\"\s]+$', '', cleaned_url)
                                                    cleaned_url = cleaned_url.rstrip('\\/')
                                                    if cleaned_url not in video_urls:
                                                        spider.logger.debug(f'Extracted video from API: {cleaned_url[:100]}...')
                                                        video_urls.append(cleaned_url)
                                except Exception as e:
                                    spider.logger.debug(f'Failed to parse API response: {str(e)[:80]}')
                    except:
                        pass

            page.on("response", handle_response)

            try:
                try:
                    page.goto(request.url, timeout=60000, wait_until='domcontentloaded')
                except:
                    try:
                        page.goto(request.url, timeout=60000, wait_until='load')
                    except:
                        page.goto(request.url, timeout=60000, wait_until='commit')

                time.sleep(3)

                try:
                    page.evaluate('window.scrollTo(0, document.body.scrollHeight / 2)')
                    time.sleep(1)
                    page.evaluate('window.scrollTo(0, 0)')
                except:
                    pass

                time.sleep(3)

                try:
                    play_button = page.query_selector('button[data-e2e="feed-play"]') or \
                                 page.query_selector('div[class*="play"]') or \
                                 page.query_selector('xg-icon[class*="play"]') or \
                                 page.query_selector('.xgplayer-play') or \
                                 page.query_selector('[aria-label*="play"]') or \
                                 page.query_selector('[class*="play-icon"]')
                    if play_button:
                        play_button.click(force=True, timeout=5000)
                        time.sleep(3)
                except Exception as e:
                    spider.logger.debug(f"Play button click failed: {str(e)[:50]}")

                time.sleep(2)
                content = page.content()

                response = HtmlResponse(
                    page.url,
                    status=200,
                    body=content.encode('utf-8'),
                    encoding='utf-8',
                    request=request
                )
                response.meta['video_urls'] = video_urls.copy()
                return response

            except Exception as e:
                import traceback
                error_msg = f'{str(e)}\n{traceback.format_exc()}'
                spider.logger.error(f'Playwright page error: {error_msg[:200]}')
                response = HtmlResponse(
                    request.url,
                    status=200,
                    body=b'',
                    encoding='utf-8',
                    request=request
                )
                response.meta['video_urls'] = video_urls.copy()
                return response
        finally:
            if page:
                try:
                    page.close()
                except:
                    pass
EOF

echo "All fixes applied successfully!"
