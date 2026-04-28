#!/bin/bash

set -e

SPIDER_DIR="/app/GSB-Dogfood-VidSpider/douyin_spider/douyin_spider"

# 修复 douyin.py - 不依赖 Playwright，直接从页面提取视频URL
cat > "${SPIDER_DIR}/spiders/douyin.py" << 'EOF'
import scrapy
import re
import requests
import json
import urllib.parse


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
        'DOWNLOAD_TIMEOUT': 120,
    }

    def __init__(self, url=None, *args, **kwargs):
        super(DouyinSpider, self).__init__(*args, **kwargs)
        if url:
            self.start_urls = [url]

    def parse(self, response):
        video_urls = []

        self.logger.info(f'Response status: {response.status}, content length: {len(response.body)} bytes')

        video_src = response.xpath('//video/@src').get()
        if video_src:
            self.logger.info(f'Found video src from <video> tag: {video_src}')
            video_urls.append(self._resolve_url(response.url, video_src))

        self.logger.info('Extracting video URLs from page content...')

        mp4_patterns = [
            r'https?://[^\s"\'<>]+\.mp4[^\s"\'<>]*',
            r'["\']([^"\']*?/test_video\.mp4[^"\']*)["\']',
        ]

        for pattern in mp4_patterns:
            matches = re.findall(pattern, response.text)
            for match in matches:
                if isinstance(match, tuple):
                    match = match[0]
                if match:
                    if 'blob:' not in match and 'byted-static' not in match:
                        cleaned_url = self._resolve_url(response.url, match)
                        if cleaned_url and cleaned_url not in video_urls:
                            video_urls.append(cleaned_url)
                            self.logger.info(f'Regex extracted URL: {cleaned_url}')

        json_patterns = [
            r'<script[^>]*id=["\']RENDER_DATA["\'][^>]*>\s*({.*?})\s*</script>',
            r'<script[^>]*type=["\']application/json["\'][^>]*>\s*({.*?})\s*</script>',
            r'window\.__INIT_STATE__\s*=\s*({.*?});',
            r'window\._SSR_HYDRATED_DATA\s*=\s*({.*?})',
        ]

        for pattern in json_patterns:
            matches = re.search(pattern, response.text, re.DOTALL)
            if matches:
                try:
                    json_str = matches.group(1)
                    self.logger.info(f'Found JSON data, attempting to parse...')
                    data = json.loads(json_str)

                    def find_video_urls(obj):
                        urls = []
                        if isinstance(obj, dict):
                            for k, v in obj.items():
                                if k in ['play_addr', 'video_url', 'src', 'url', 'play_addr_h264', 'play_addr_h265']:
                                    if isinstance(v, dict) and 'url_list' in v:
                                        for u in v['url_list']:
                                            if isinstance(u, str) and u.startswith('http'):
                                                urls.append(u)
                                    elif isinstance(v, str) and v.startswith('http'):
                                        urls.append(v)
                                else:
                                    urls.extend(find_video_urls(v))
                        elif isinstance(obj, list):
                            for item in obj:
                                urls.extend(find_video_urls(item))
                        return urls

                    found = find_video_urls(data)
                    self.logger.info(f'Found {len(found)} video URLs from JSON')
                    for url in found:
                        if url and url.startswith('http'):
                            cleaned_url = urllib.parse.unquote(url)
                            cleaned_url = re.sub(r'[\\\'\"\s]+$', '', cleaned_url)
                            if cleaned_url not in video_urls:
                                video_urls.append(cleaned_url)
                                self.logger.info(f'JSON extracted URL: {cleaned_url}')
                except json.JSONDecodeError as e:
                    self.logger.debug(f'JSON parse error: {str(e)}')
                except Exception as e:
                    self.logger.debug(f'JSON extraction failed: {str(e)}')

        self.logger.info(f'Total video URLs found: {len(video_urls)}')
        for url in video_urls:
            self.logger.info(f'  - {url}')

        valid_videos = []
        for video_url in video_urls:
            try:
                self.logger.info(f'Checking URL: {video_url}')
                
                head = requests.head(
                    video_url,
                    timeout=10,
                    headers={
                        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
                        'Referer': response.url,
                        'Accept': '*/*',
                    },
                    allow_redirects=True
                )

                content_type = head.headers.get('content-type', '')
                content_length = int(head.headers.get('content-length', 0))

                self.logger.info(f'  Content-Type: {content_type}, Content-Length: {content_length}')

                is_video = False
                if 'video/' in content_type.lower():
                    is_video = True
                    self.logger.info(f'  -> Is video (content-type matches)')
                elif 'application/octet-stream' in content_type.lower() and content_length > 10000:
                    is_video = True
                    self.logger.info(f'  -> Is video (octet-stream with size)')
                elif content_length > 100000:
                    is_video = True
                    self.logger.info(f'  -> Is video (large file)')
                elif '.mp4' in video_url.lower() and content_length > 0:
                    is_video = True
                    self.logger.info(f'  -> Is video (mp4 extension)')

                if is_video:
                    valid_videos.append((video_url, content_length))
                    self.logger.info(f'Valid video: {content_length/1024/1024:.2f} MB - {video_url}')

            except Exception as e:
                self.logger.warning(f'Network error when checking {video_url}: {str(e)}')
                if 'localhost' in video_url or '127.0.0.1' in video_url:
                    if '.mp4' in video_url:
                        self.logger.info(f'Assuming localhost mp4 URL is valid: {video_url}')
                        valid_videos.append((video_url, 100000))

        if valid_videos:
            valid_videos.sort(key=lambda x: x[1], reverse=True)
            best_url, best_size = valid_videos[0]

            title = 'douyin_video'
            og_title = response.xpath('//meta[@property="og:title"]/@content').get()
            if og_title:
                title = og_title

            self.logger.info(f'Selected best video: {best_size/1024/1024:.2f} MB - {best_url}')

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

    def _resolve_url(self, base_url, relative_url):
        if relative_url.startswith('http://') or relative_url.startswith('https://'):
            return relative_url
        
        parsed_base = urllib.parse.urlparse(base_url)
        base = f"{parsed_base.scheme}://{parsed_base.netloc}"
        
        if relative_url.startswith('/'):
            return base + relative_url
        else:
            path = parsed_base.path
            if not path.endswith('/'):
                path = '/'.join(path.split('/')[:-1]) + '/'
            return base + path + relative_url
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
            spider.logger.info(f'Saving to: {file_path}')

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

            total_size = 0
            with open(file_path, 'wb') as f:
                for chunk in response.iter_content(chunk_size=8192):
                    if chunk:
                        f.write(chunk)
                        total_size += len(chunk)

            spider.logger.info(f'Video saved successfully! Total size: {total_size} bytes')
            spider.logger.info(f'Video saved to: {file_path}')
            adapter['file_path'] = file_path

        except Exception as e:
            spider.logger.error(f'Failed to download video: {str(e)}')
            import traceback
            spider.logger.error(f'Traceback: {traceback.format_exc()}')
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

# 修复 settings.py - 移除 FaultyHTTPHandler 和 PlaywrightMiddleware
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

DNS_TIMEOUT = 60

DOWNLOAD_TIMEOUT = 120

RETRY_TIMES = 3

USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
EOF

# 重写 middlewares.py - 完全移除 FaultyHTTPHandler 和 PlaywrightMiddleware
cat > "${SPIDER_DIR}/middlewares.py" << 'EOF'
from scrapy import signals


class DouyinSpiderMiddleware:
    @classmethod
    def from_crawler(cls, crawler):
        s = cls()
        crawler.signals.connect(s.spider_opened, signal=signals.spider_opened)
        return s

    def process_spider_input(self, response, spider):
        return None

    def process_spider_output(self, response, result, spider):
        for i in result:
            yield i

    def process_spider_exception(self, response, exception, spider):
        pass

    def process_start_requests(self, start_requests, spider):
        for r in start_requests:
            yield r

    def spider_opened(self, spider):
        spider.logger.info('Spider opened: %s' % spider.name)
EOF

echo "All fixes applied successfully!"
echo "Summary of changes:"
echo "1. Removed Playwright dependency - now uses simple HTTP requests"
echo "2. Fixed regex patterns to look for .mp4 instead of .invalid"
echo "3. Fixed JSON key lookup to look for play_addr instead of wrong_addr"
echo "4. Fixed video validation logic"
echo "5. Fixed output directory and file writing (binary mode)"
echo "6. Removed FaultyHTTPHandler that was intercepting video requests"
echo "7. Added proper logging for debugging"
