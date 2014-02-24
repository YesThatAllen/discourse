#
# Handles an incoming message
#

module Email
  class Receiver

    def self.results
      @results ||= Enum.new(:unprocessable, :missing, :processed, :error)
    end

    attr_reader :body, :reply_key, :email_log

    def initialize(raw)
      @raw = raw
    end

    def process
      return Email::Receiver.results[:unprocessable] if @raw.blank?

      @message = Mail::Message.new(@raw)


      # First remove the known discourse stuff.
      parse_body
      return Email::Receiver.results[:unprocessable] if @body.blank?

      # Then run the github EmailReplyParser on it in case we didn't catch it
      @body = EmailReplyParser.read(@body).visible_text.force_encoding('UTF-8')

      discourse_email_parser

      return Email::Receiver.results[:unprocessable] if @body.blank?
      @reply_key = @message.to.first

      # Extract the `reply_key` from the format the site has specified
      tokens = SiteSetting.reply_by_email_address.split("%{reply_key}")
      tokens.each do |t|
        @reply_key.gsub!(t, "") if t.present?
      end

      # Look up the email log for the reply key, or create a new post if there is none
      # Enabled when config/discourse.conf contains "allow_new_topics_from_email = true"
      @email_log = EmailLog.for(reply_key)
      if @email_log.blank?
     	return Email::Receiver.results[:unprocessable] if GlobalSetting.allow_new_topics_from_email == false
        @subject = @message.subject
        @user_info = User.find_by_email(@message.from.first)
        return Email::Receiver.results[:unprocessable] if @user_info.blank?
        Rails.logger.debug "Creating post from #{@message.from.first} with subject #{@subject}"
        create_new
      else
        create_reply
      end
      Email::Receiver.results[:processed]
    rescue
      Email::Receiver.results[:error]
    end

    private

    def parse_body
      html = nil

      # If the message is multipart, find the best type for our purposes
      if @message.multipart?
        @message.parts.each do |p|
          if p.content_type =~ /text\/plain/
            @body = p.charset ? p.body.decoded.force_encoding(p.charset).encode("UTF-8").to_s : p.body.to_s
            return @body
          elsif p.content_type =~ /text\/html/
            html = p.charset ? p.body.decoded.force_encoding(p.charset).encode("UTF-8").to_s : p.body.to_s
          end
        end
      end

      if @message.content_type =~ /text\/html/
        if defined? @message.charset
          html = @message.body.decoded.force_encoding(@message.charset).encode("UTF-8").to_s 
        else
          html = @message.body.to_s
        end
      end
      if html.present?
        @body = scrub_html(html)
        return @body
      end

      @body = @message.charset ? @message.body.decoded.force_encoding(@message.charset).encode("UTF-8").to_s.strip : @message.body.to_s

      # Certain trigger phrases that means we didn't parse correctly
      @body = nil if @body =~ /Content\-Type\:/ ||
                     @body =~ /multipart\/alternative/ ||
                     @body =~ /text\/plain/

      @body
    end

    def scrub_html(html)
      # If we have an HTML message, strip the markup
      doc = Nokogiri::HTML(html)

      # Blackberry is annoying in that it only provides HTML. We can easily
      # extract it though
      content = doc.at("#BB10_response_div")
      return content.text if content.present?

      return doc.xpath("//text()").text
    end

    def discourse_email_parser
      lines = @body.scrub.lines.to_a
      range_end = 0

      lines.each_with_index do |l, idx|
        break if l =~ /\A\s*\-{3,80}\s*\z/ ||
                 l =~ Regexp.new("\\A\\s*" + I18n.t('user_notifications.previous_discussion') + "\\s*\\Z") ||
                 (l =~ /via #{SiteSetting.title}(.*)\:$/) ||
                 # This one might be controversial but so many reply lines have years, times and end with a colon.
                 # Let's try it and see how well it works.
                 (l =~ /\d{4}/ && l =~ /\d:\d\d/ && l =~ /\:$/)

        range_end = idx
      end

      @body = lines[0..range_end].join
      @body.strip!
    end

    def create_reply
      # Try to post the body as a reply
      creator = PostCreator.new(email_log.user,
                                raw: @body,
                                topic_id: @email_log.topic_id,
                                reply_to_post_number: @email_log.post.post_number,
                                cooking_options: {traditional_markdown_linebreaks: true})

      creator.create
    end
    def create_new
      # Try to create a new topic with the body and subject
      # looking to config/discourse.conf to set category 
      if defined? GlobalSetting.default_categories_id
        @categoryID = 1
      else 
        @categoryID = GlobalSetting.default_categories_id
      end
      creator = PostCreator.new(@user_info,
                                title: @subject,
                                raw: @body,
                                category: @categoryID,
                                cooking_options: {traditional_markdown_linebreaks: true})
      creator.create
    end

  end
end
