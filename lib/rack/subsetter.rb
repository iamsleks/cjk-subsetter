require 'rack'
require 'nokogiri'
require 'digest/sha1'
require 'erb'
require 'pathname'
require 'posix/spawn'

module Rack
  class Subsetter
    def initialize(app, options={})
      @app = app
      @prefix = options[:prefix]
      @font_map = options[:font_map]
      @font_source = options[:font_source]
      @public_path = options[:font_dist][:public_path]
      @font_dist = ::File.expand_path(options[:font_dist][:dir], @public_path)
      @sfnttool = ::File.expand_path("../tools/sfnttool.jar", __FILE__)
    end

    def should_subset(str)
      !!(str =~ /\p{Han}|\p{Katakana}|\p{Hiragana}|\p{Hangul}|\p{Punctuation}|\p{Word}/)
    end

    def create_subset_map(html)
      doc = Nokogiri::HTML(html)
      doc.search('[class*="%s"]' % @prefix).each do |element|
        type = /#{@prefix}-(\w+)/.match(element['class'])[1]
        unless @subset_string_map[type]
          @subset_string_map[type] = Hash.new
        end
        set_subset_map(type, element.inner_text)
      end
    end

    def set_subset_map(type, string)
      string.each_char do |s|
        next unless should_subset(s)
        @subset_string_map[type][s] = 1
      end
    end

    def html?(headers)
      headers['Content-Type'] =~ /html/
    end

    def create_path(string, font_name)
      filename = Digest::SHA1.hexdigest(string + font_name)
      @font_dist + '/' + filename + '.ttf'
    end

    def call(env)
      @path = @font_dist

      status, headers, body = @app.call(env)
      return [status, headers, body] unless html? headers

      response = Rack::Response.new([], status, headers)
      new_body = ""
      @subset_string_map = Hash.new

      body.each do |string|
        create_subset_map(string)
        new_body << " " << string
      end

      p_public = Pathname.new @public_path
      template = ::ERB.new ::File.read ::File.expand_path("../style.erb", __FILE__)

      @subset_string_map.each do |font_key, chars_map|
        subset_string = chars_map.map { |key, value| key }.join
        font_name = @font_map[font_key].join
        file_path = create_path(subset_string, font_name)

        unless ::File.exist? file_path
          ::File.open(file_path, 'w+')
          child = POSIX::Spawn::Child.new('java', "-jar", "#{@sfnttool}", "-s", \
            "#{subset_string}", "#{@font_source}/#{font_name}", "#{file_path}")
        end

        p_output = Pathname.new file_path
        relative_path = p_output.relative_path_from p_public
        klass = '.%s-' % @prefix + font_key
        new_body.gsub!(%r{</head>}, template.result(binding) + "</head>")
      end

      response.write new_body
      response.finish
    end
  end
end