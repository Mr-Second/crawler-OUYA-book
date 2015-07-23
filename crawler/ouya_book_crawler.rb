require 'crawler_rocks'
require 'iconv'
require 'pry'

require 'book_toolkit'

require 'thread'
require 'thwait'

class OuyaBookCrawler
  include CrawlerRocks::DSL

  def initialize update_progress: nil, after_each: nil
    @update_progress_proc = update_progress
    @after_each_proc = after_each

    @index_url = "http://www.eurasia.com.tw/product/books.asp"
    @query_url = "http://www.eurasia.com.tw/product/books_sub.asp"
    @base_url = "http://www.eurasia.com.tw/product/"

    @ic = Iconv.new("utf-8//translit//IGNORE","big5")
  end

  def books
    @books = []
    @threads = []
    @detail_threads = []

    visit @index_url

    post @query_url, {
        "show_table" => 'y',
        "page" => 1,
        "all" => '',
        "SSS" => 'sea',
    }

    page_num = 0
    @doc.css('td font[color="#666666"]').text.match(/查詢結果共(?<total>\d+)筆/) do |m|
      page_num = m[:total].to_i / 10 + 1
    end

    (1..page_num).each do |i|
      sleep(1) until (
        @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
        @threads.count < (ENV['MAX_THREADS'] || 20)
      )
      @threads << Thread.new do
        r = RestClient.post @query_url, {
          "show_table" => 'y',
          "page" => i,
          "all" => '',
          "SSS" => 'sea',
        }, cookies: @cookies

        doc = Nokogiri::HTML(@ic.iconv r)
        doc.css('tr[bgcolor="#66CCFF"]:not(:last-child)').each do |row|
          sleep(1) until (
            @detail_threads.delete_if { |t| !t.status };  # remove dead (ended) threads
            @detail_threads.count < (ENV['MAX_THREADS'] || 10)
          )
          @detail_threads << Thread.new do
            datas = row.css('td')

            rel_url = datas[0] && !datas[0].css('a').empty? && datas[0].css('a')[0][:href]
            url = @base_url + rel_url

            original_price = datas[5] && datas[5].text.to_i
            original_price = nil if original_price == 0

            r = RestClient.get url
            detail_doc = Nokogiri::HTML(@ic.iconv r)

            publisher = nil; edition = nil;
            detail_doc.css('tr').map{|tr| tr.text.scrub.gsub(/\s+/, ' ').strip;}.each do |tr_text|
              tr_text.match(/出版商\u{ff1a}\s(?<pub>.+?)\s/){|m| publisher ||= m[:pub]}
              tr_text.match(/版　次\u{ff1a}\s(?<edi>\d+?)\s/){|m| publisher ||= m[:edi].to_i}
            end

            isbn = nil; invalid_isbn = nil;
            begin
              isbn = datas[2] && BookToolkit.to_isbn13(datas[2].text.strip)
            rescue Exception => e
              invalid_isbn = datas[2] && datas[2].text.strip
            end

            book = {
              name: datas[3] && datas[3].text.strip.gsub(/\w+/, &:capitalize),
              author: datas[4] && datas[4].text.strip.capitalize,
              isbn: isbn,
              invalid_isbn: invalid_isbn,
              internal_code: datas[0] && datas[0].text.strip,
              publisher: publisher,
              edition: edition,
              url: url,
              original_price: original_price,
              known_supplier: 'ouya'
            }

            @after_each_proc.call(book: book) if @after_each_proc

            @books << book
          end
        end # each row do
        ThreadsWait.all_waits(*@detail_threads)
        puts i
      end # thread new do
    end # each page
    ThreadsWait.all_waits(*@threads)
    @books
  end # end books
end

# cc = OuyaBookCrawler.new
# File.write('ouya_books.json', JSON.pretty_generate(cc.books))
