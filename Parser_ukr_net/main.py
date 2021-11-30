import get_news_categories

url = 'https://ukr.net'

main_text = get_news_categories.get_url_source(url)
news_categories_list = get_news_categories.find_news_categories(main_text)
headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.45 Safari/537.36'}

for item in news_categories_list:
    try:
        print (f"Parse URL {item.url}")
        news = get_news_categories.get_news_inside(item.url, headers)
        print(news)
        

    except:
        print (f"Bad URL {item.url}")



