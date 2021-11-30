from lxml import html
from bs4 import BeautifulSoup
import lxml

import requests

def get_url_source(url,headers=''):

    r = requests.get(url,headers)
    r.encoding = 'utf-8'
    return r.text

#Get all content of Ukr.net
#headers = {'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.9; rv:45.0) Gecko/20100101 Firefox/45.0'}
#r = requests.get(url, headers=headers)

#Get headres of news
#Search <h2> and Get name and uri
class NewsCategories():

    def __init__(self, name, url) -> None:
        self.url = url
        self.name = name
    
    def __str__(self) -> str:
        return self.name + ' ' + self.url

#found <h2>
#get string beetween <h2> and </h2>
#split string to uri and name and create new object NewsCategories()
def find_news_categories(text):
    soup = BeautifulSoup(text)
    result = []
    news_categories = soup.find_all('h2')
    for ch in news_categories:
        name = ch.text
        url = 'https:'+ch.contents[0].attrs['href']
        result.append(NewsCategories(name,url))
        print(url)
    return result


def get_news_inside(url, headers):
    soup = BeautifulSoup(get_url_source(url,headers,features=lxml))
    return soup