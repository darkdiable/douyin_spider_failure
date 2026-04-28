# douyin_spider_failure
这是一个部署在容器环境中的视频爬虫测试系统(基于用于大语言模型agent测试的harbor框架，harbor框架会自动执行solution/solve.sh,然后执行tests/test.sh去验证，结果仅reward为1时表示问题修复)。爬虫代码是按照抖音网站结构设计的，但在测试环境中，所有请求都会指向本地启动的模拟服务（localhost:9999），而非真实的抖音网站。当前问题表现：目前执行python3 -m scrapy crawl douyin -a url="&lt;http://localhost:9999/"命令时，系统未能成功下载测试视频。输出目录/app/GSB-Dogfood-VidSpider/douyinOutput
