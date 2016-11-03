require_relative '../dice'
require_relative '../quote_generator'

module DiscourseNarrativeBot
  class NewUserNarrative
    TRANSITION_TABLE = {
      [:begin, :init] => {
        next_state: :waiting_reply,
        action: :say_hello
      },

      [:begin, :reply] => {
        next_state: :waiting_reply,
        action: :say_hello
      },

      [:waiting_reply, :reply] => {
        next_state: :tutorial_topic,
        action: :quote_user_reply
      },

      [:tutorial_topic, :reply] => {
        next_state: :tutorial_onebox,
        next_instructions_key: 'onebox.instructions',
        action: :reply_to_topic
      },

      [:tutorial_onebox, :reply] => {
        next_state: :tutorial_images,
        next_instructions_key: 'images.instructions',
        action: :reply_to_onebox
      },

      [:tutorial_images, :reply] => {
        next_state: :tutorial_formatting,
        next_instructions_key: 'formatting.instructions',
        action: :reply_to_image
      },

      [:tutorial_formatting, :reply] => {
        next_state: :tutorial_quote,
        next_instructions_key: 'quoting.instructions',
        action: :reply_to_formatting
      },

      [:tutorial_quote, :reply] => {
        next_state: :tutorial_emoji,
        next_instructions_key: 'emoji.instructions',
        action: :reply_to_quote
      },

      [:tutorial_emoji, :reply] => {
        next_state: :tutorial_mention,
        next_instructions_key: 'mention.instructions',
        action: :reply_to_emoji
      },

      [:tutorial_mention, :reply] => {
        next_state: :tutorial_link,
        next_instructions_key: 'link.instructions',
        action: :reply_to_mention
      },

      [:tutorial_link, :reply] => {
        next_state: :tutorial_pm,
        next_instructions_key: 'pm.instructions',
        action: :reply_to_link
      },

      [:tutorial_pm, :reply] => {
        next_state: :end,
        action: :reply_to_pm
      }
    }

    RESET_TRIGGER = '/reset_bot'.freeze
    DICE_TRIGGER = 'roll'.freeze
    TIMEOUT_DURATION = 900 # 15 mins

    class InvalidTransitionError < StandardError; end
    class DoNotUnderstandError < StandardError; end
    class TransitionError < StandardError; end

    def input(input, user, post)
      @data = DiscourseNarrativeBot::Store.get(user.id) || {}
      @state = (@data[:state] && @data[:state].to_sym) || :begin
      @input = input
      @user = user
      @post = post
      opts = {}

      return if reset_bot?

      begin
        opts = transition
      rescue DoNotUnderstandError
        generic_replies
        return
      rescue TransitionError
        mention_replies
        return
      end

      new_state = opts[:next_state]
      action = opts[:action]

      if next_instructions_key = opts[:next_instructions_key]
        @next_instructions_key = next_instructions_key
      end

      if new_post = self.send(action)
        @data[:state] = new_state
        @data[:last_post_id] = new_post.id
        store_data

        if new_state == :end
          end_reply
          cancel_timeout_job(user)
        end
      end
    end

    def notify_timeout(user)
      @data = DiscourseNarrativeBot::Store.get(user.id) || {}

      if post = Post.find_by(id: @data[:last_post_id])
        reply_to(
          raw: I18n.t(i18n_key("timeout.message"), username: user.username),
          topic_id: post.topic.id,
          reply_to_post_number: post.post_number
        )
      end
    end

    private

    def say_hello
      raw = I18n.t(
        i18n_key("hello.message_#{Time.now.to_i % 6 + 1}"),
        username: @user.username,
        title: SiteSetting.title
      )

      if @input == :init
        reply_to(raw: raw, topic_id: SiteSetting.discobot_welcome_topic_id)
      else
        return unless bot_mentioned?

        fake_delay
        like_post

        reply_to(
          raw: raw,
          topic_id: @post.topic.id,
          reply_to_post_number: @post.post_number
        )
      end
    end

    def quote_user_reply
      post_topic_id = @post.topic.id
      return unless post_topic_id == SiteSetting.discobot_welcome_topic_id

      fake_delay
      like_post

      reply = reply_to(
        raw: I18n.t(i18n_key('quote_user_reply'),
          username: @post.user.username,
          post_id: @post.id,
          topic_id: post_topic_id,
          post_raw: @post.raw,
          category_slug: Category.find(SiteSetting.discobot_category_id).slug
        ),
        topic_id: post_topic_id,
        reply_to_post_number: @post.post_number
      )

      enqueue_timeout_job(@user)
      reply
    end

    def reply_to_topic
      return unless @post.topic.category_id == SiteSetting.discobot_category_id
      return unless @post.is_first_post?

      post_topic_id = @post.topic.id
      @data[:topic_id] = post_topic_id

      unless key = @post.raw.match(/(unicorn|bacon|ninja|monkey)/i)
        return
      end

      raw = <<~RAW
        #{I18n.t(i18n_key(Regexp.last_match.to_s.downcase))}

        #{I18n.t(i18n_key(@next_instructions_key))}
      RAW

      fake_delay
      like_post

      reply = reply_to(
        raw: raw,
        topic_id: post_topic_id,
        reply_to_post_number: @post.post_number
      )

      enqueue_timeout_job(@user)
      reply
    end

    def reply_to_onebox
      post_topic_id = @post.topic.id
      return unless valid_topic?(post_topic_id)

      @post.post_analyzer.cook(@post.raw, {})

      if @post.post_analyzer.found_oneboxes?
        raw = <<~RAW
          #{I18n.t(i18n_key('onebox.reply'))}

          #{I18n.t(i18n_key(@next_instructions_key))}
        RAW

        fake_delay
        like_post

        reply = reply_to(
          raw: raw,
          topic_id: post_topic_id,
          reply_to_post_number: @post.post_number
        )

        enqueue_timeout_job(@user)
        reply
      else
        fake_delay

        reply_to(
          raw: I18n.t(i18n_key('onebox.not_found')),
          topic_id: post_topic_id,
          reply_to_post_number: @post.post_number
        )

        enqueue_timeout_job(@user)
        false
      end
    end

    def reply_to_image
      post_topic_id = @post.topic.id
      return unless valid_topic?(post_topic_id)

      @post.post_analyzer.cook(@post.raw, {})

      if @post.post_analyzer.image_count > 0
        raw = <<~RAW
          #{I18n.t(i18n_key('images.reply'))}

          #{I18n.t(i18n_key(@next_instructions_key))}
        RAW

        fake_delay
        like_post

        reply = reply_to(
          raw: raw,
          topic_id: post_topic_id,
          reply_to_post_number: @post.post_number
        )

        enqueue_timeout_job(@user)
        reply
      else
        fake_delay

        reply_to(
          raw: I18n.t(i18n_key('images.not_found')),
          topic_id: post_topic_id,
          reply_to_post_number: @post.post_number
        )

        enqueue_timeout_job(@user)
        false
      end
    end

    def reply_to_formatting
      post_topic_id = @post.topic.id
      return unless valid_topic?(post_topic_id)

      if Nokogiri::HTML.fragment(@post.cooked).css("b", "strong", "em", "i").size > 0
        raw = <<~RAW
          #{I18n.t(i18n_key('formatting.reply'))}

          #{I18n.t(i18n_key(@next_instructions_key))}
        RAW

        fake_delay
        like_post

        reply = reply_to(
          raw: raw,
          topic_id: post_topic_id,
          reply_to_post_number: @post.post_number
        )

        enqueue_timeout_job(@user)
        reply
      else
        fake_delay

        reply_to(
          raw: I18n.t(i18n_key('formatting.not_found')),
          topic_id: post_topic_id,
          reply_to_post_number: @post.post_number
        )

        enqueue_timeout_job(@user)
        false
      end
    end

    def reply_to_quote
      post_topic_id = @post.topic.id
      return unless valid_topic?(post_topic_id)

      doc = Nokogiri::HTML.fragment(@post.cooked)

      if doc.css(".quote").size > 0
        raw = <<~RAW
          #{I18n.t(i18n_key('quoting.reply'))}

          #{I18n.t(i18n_key(@next_instructions_key))}
        RAW

        fake_delay
        like_post

        reply = reply_to(
          raw: raw,
          topic_id: post_topic_id,
          reply_to_post_number: @post.post_number
        )

        enqueue_timeout_job(@user)
        reply
      else
        fake_delay

        reply_to(
          raw: I18n.t(i18n_key('quoting.not_found')),
          topic_id: post_topic_id,
          reply_to_post_number: @post.post_number
        )

        enqueue_timeout_job(@user)
        false
      end
    end

    def reply_to_emoji
      post_topic_id = @post.topic.id
      return unless valid_topic?(post_topic_id)

      doc = Nokogiri::HTML.fragment(@post.cooked)

      if doc.css(".emoji").size > 0
        raw = <<~RAW
          #{I18n.t(i18n_key('emoji.reply'))}

          #{I18n.t(i18n_key(@next_instructions_key))}
        RAW

        fake_delay
        like_post

        reply = reply_to(
          raw: raw,
          topic_id: post_topic_id,
          reply_to_post_number: @post.post_number
        )

        enqueue_timeout_job(@user)
        reply
      else
        fake_delay

        reply_to(
          raw: I18n.t(i18n_key('emoji.not_found')),
          topic_id: post_topic_id,
          reply_to_post_number: @post.post_number
        )

        enqueue_timeout_job(@user)
        false
      end
    end

    def reply_to_mention
      post_topic_id = @post.topic.id
      return unless valid_topic?(post_topic_id)

      if bot_mentioned?
        raw = <<~RAW
          #{I18n.t(i18n_key('mention.reply'))}

          #{I18n.t(i18n_key(@next_instructions_key), topic_id: SiteSetting.discobot_welcome_topic_id)}
        RAW

        fake_delay
        like_post

        reply = reply_to(
          raw: raw,
          topic_id: post_topic_id,
          reply_to_post_number: @post.post_number
        )

        enqueue_timeout_job(@user)
        reply
      else
        fake_delay

        reply_to(
          raw: I18n.t(i18n_key('mention.not_found'), username: @user.username),
          topic_id: post_topic_id,
          reply_to_post_number: @post.post_number
        )

        enqueue_timeout_job(@user)
        false
      end
    end

    def bot_mentioned?
      doc = Nokogiri::HTML.fragment(@post.cooked)

      valid = false

      doc.css(".mention").each do |mention|
        valid = true if mention.text == "@#{self.class.discobot_user.username}"
      end

      valid
    end

    def reply_to_link
      post_topic_id = @post.topic.id
      return unless valid_topic?(post_topic_id)

      @post.post_analyzer.cook(@post.raw, {})

      if @post.post_analyzer.link_count > 0
        raw = <<~RAW
          #{I18n.t(i18n_key('link.reply'))}

          #{I18n.t(i18n_key(@next_instructions_key))}
        RAW

        fake_delay
        like_post

        reply = reply_to(
          raw: raw,
          topic_id: post_topic_id,
          reply_to_post_number: @post.post_number
        )

        enqueue_timeout_job(@user)
        reply
      else
        fake_delay

        reply_to(
          raw: I18n.t(i18n_key('link.not_found'), topic_id: SiteSetting.discobot_welcome_topic_id),
          topic_id: post_topic_id,
          reply_to_post_number: @post.post_number
        )

        enqueue_timeout_job(@user)
        false
      end
    end

    def reply_to_pm
      if @post.archetype == Archetype.private_message &&
        @post.topic.allowed_users.any? { |p| p.id == self.class.discobot_user.id }

        fake_delay
        like_post

        reply_to(
          raw: I18n.t(i18n_key('pm.message')),
          topic_id: @post.topic.id,
          reply_to_post_number: @post.post_number
        )
      end
    end

    def end_reply
      fake_delay

      reply_to(
        raw: I18n.t(i18n_key('end.message'),
          username: @user.username,
          category_slug: Category.find(SiteSetting.discobot_category_id).slug
        ),
        topic_id: @data[:topic_id]
      )
    end

    def valid_topic?(topic_id)
      topic_id == @data[:topic_id]
    end

    def reply_to_bot_post?
      @post&.reply_to_post && @post.reply_to_post.user_id == -2
    end

    def transition
      if @post
        topic_id = @post.topic.id
        valid_topic = valid_topic?(topic_id)

        if !valid_topic && topic_id != SiteSetting.discobot_welcome_topic_id
          raise TransitionError.new if bot_mentioned?
          raise DoNotUnderstandError.new if reply_to_bot_post?
        elsif valid_topic && @state == :end
          raise DoNotUnderstandError.new if reply_to_bot_post?
        end
      end

      TRANSITION_TABLE.fetch([@state, @input])
    rescue KeyError
      raise InvalidTransitionError.new("No transition from state '#{@state}' for input '#{@input}'")
    end

    def i18n_key(key)
      "discourse_narrative_bot.new_user_narrative.#{key}"
    end

    def reply_to(opts)
      PostCreator.create!(self.class.discobot_user, opts)
    end

    def fake_delay
      sleep(rand(2..3)) if Rails.env.production?
    end

    def like_post
      PostAction.act(self.class.discobot_user, @post, PostActionType.types[:like])
    end

    def generic_replies
      count = (@data[:do_not_understand_count] ||= 0)

      case count
      when 0
        reply_to(
          raw: I18n.t(i18n_key('do_not_understand.first_response')),
          topic_id: @post.topic.id,
          reply_to_post_number: @post.post_number
        )
      when 1
        reply_to(
          raw: I18n.t(i18n_key('do_not_understand.second_response')),
          topic_id: @post.topic.id,
          reply_to_post_number: @post.post_number
        )
      else
        # Stay out of the user's way
      end

      @data[:do_not_understand_count] += 1
      store_data
    end

    def mention_replies
      post_raw = @post.raw

      raw =
        if match_data = post_raw.match(/roll dice (\d+)d(\d+)/i)
          I18n.t(i18n_key('random_mention.dice'),
            results: Dice.new(match_data[1].to_i, match_data[2].to_i).roll.join(", ")
          )
        elsif match_data = post_raw.match(/show me a quote/i)
          I18n.t(i18n_key('random_mention.quote'), QuoteGenerator.generate)
        else
          I18n.t(i18n_key('random_mention.message'))
        end

      like_post
      fake_delay

      reply_to(
        raw: raw,
        topic_id: @post.topic.id,
        reply_to_post_number: @post.post_number
      )
    end

    def reset_bot?
      reset = false

      if @post &&
         bot_mentioned? &&
         [@data[:topic_id], SiteSetting.discobot_welcome_topic_id].include?(@post.topic.id) &&
         @post.raw.match(/#{RESET_TRIGGER}/)

        reset_data
        fake_delay

        raw =
          if @data[:topic_id] == @post.topic.id
            I18n.t(i18n_key('reset.message'), topic_id: SiteSetting.discobot_welcome_topic_id)
          elsif SiteSetting.discobot_welcome_topic_id == @post.topic.id
            I18n.t(i18n_key('reset.welcome_topic_message'))
          end

        reply_to(
          raw: raw,
          topic_id: @post.topic.id,
          reply_to_post_number: @post.post_number
        )

        reset = true
      end

      reset
    end

    def cancel_timeout_job(user)
      Jobs.cancel_scheduled_job(:narrative_timeout, user_id: user.id)
    end

    def enqueue_timeout_job(user)
      cancel_timeout_job(user)
      Jobs.enqueue_in(TIMEOUT_DURATION, :narrative_timeout, user_id: user.id)
    end

    def store_data
      set_data(@data)
    end

    def reset_data
      set_data(nil)
    end

    def set_data(value)
      DiscourseNarrativeBot::Store.set(@user.id, value)
    end

    def self.discobot_user
      @discobot ||= User.find(-2)
    end
  end
end
