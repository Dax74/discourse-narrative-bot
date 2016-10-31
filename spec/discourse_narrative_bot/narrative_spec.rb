require 'rails_helper'

describe DiscourseNarrativeBot::Narrative do
  let(:category) { Fabricate(:category) }
  let(:welcome_topic) { Fabricate(:topic, category: category) }
  let(:topic) { Fabricate(:topic, category: category) }
  let(:user) { Fabricate(:user) }
  let(:post) { Fabricate(:post, topic: topic) }
  let(:narrative) { described_class.new }
  let(:other_topic) { Fabricate(:topic) }
  let(:other_post) { Fabricate(:post, topic: other_topic) }

  describe 'Bot initiation' do
    let(:group) { Fabricate(:group) }
    let(:other_group) { Fabricate(:group, name: 'test') }

    describe 'restricted bot category' do
      describe 'when creating a new user' do
        describe 'and user is allowed to view category' do
          let(:category)  { Fabricate(:category, read_restricted: true, groups: [group]) }
          let(:welcome_topic) { Fabricate(:topic, category: category) }

          before do
            SiteSetting.discobot_category_id = category.id
            SiteSetting.discobot_welcome_topic_id = welcome_topic.id
          end

          it 'should initiate the bot for the user' do
            category
            user

            expect { user.groups << [group, other_group] }.to change { Post.count }.by(1)
            expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:waiting_reply)
          end
        end

        describe 'and user is not allowed to view category' do
          it 'should not initiate the bot' do
            category
            user

            expect { user.groups << [group, other_group] }.to change { Post.count }.by(0)
            expect(DiscourseNarrativeBot::Store.get(user.id)).to eq(nil)
          end
        end
      end
    end

    describe 'unrestricted bot category' do
      describe 'when creating a new user' do
        before do
          SiteSetting.discobot_category_id = category.id
          SiteSetting.discobot_welcome_topic_id = welcome_topic.id
        end

        it 'should initiate the bot for the user' do
          category
          user

          expect { user.groups << [group, other_group] }.to change { Post.count }.by(1)
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:waiting_reply)
        end
      end
    end
  end

  describe '#notify_timeout' do
    before do
      DiscourseNarrativeBot::Store.set(user.id,
        state: :tutorial_topic,
        topic_id: topic.id,
        last_post_id: post.id
      )
    end

    it 'should create the right message' do
      expect { narrative.notify_timeout(user) }.to change { Post.count }.by(1)

      expect(Post.last.raw).to eq(I18n.t(
        'discourse_narrative_bot.narratives.timeout.message',
        username: user.username
      ))
    end
  end

  describe '#input' do
    before do
      SiteSetting.discobot_category_id = category.id
      SiteSetting.discobot_welcome_topic_id = welcome_topic.id
      SiteSetting.title = "This is an awesome site!"
      DiscourseNarrativeBot::Store.set(user.id, state: :begin)
    end

    describe 'when post contains the right reset trigger' do
      before do
        DiscourseNarrativeBot::Store.set(user.id, state: :tutorial_topic, topic_id: topic.id)
      end

      describe 'in the new bot topic' do
        it 'should reset the bot' do
          post.update_attributes!(raw: "@discobot something #{described_class::RESET_TRIGGER}")
          narrative.input(:reply, user, post)

          expect(DiscourseNarrativeBot::Store.get(user.id)).to eq(nil)

          expect(Post.last.raw).to eq(I18n.t(
            'discourse_narrative_bot.narratives.reset.message',
            topic_id: SiteSetting.discobot_welcome_topic_id
          ))
        end
      end

      describe 'in the bot welcome topic' do
        it 'should reset the bot' do
          new_post = Fabricate(:post,
            topic_id: SiteSetting.discobot_welcome_topic_id,
            raw: "something #{described_class::RESET_TRIGGER} @discobot"
          )

          narrative.input(:reply, user, new_post)

          expect(DiscourseNarrativeBot::Store.get(user.id)).to eq(nil)

          expect(Post.last.raw).to eq(I18n.t(
            'discourse_narrative_bot.narratives.reset.welcome_topic_message',
          ))
        end
      end
    end

    describe 'when input does not have a valid transition from current state' do
      it 'should raise the right error' do
        expect { narrative.input(:something, user, post) }.to raise_error(
          described_class::TransitionError,
          "No transition from state 'begin' for input 'something'"
        )
      end
    end

    describe 'when [:begin, :init]' do
      it 'should create the right post' do
        Timecop.freeze(Time.new(2016, 10, 31, 16, 30)) do
          narrative.input(:init, user, nil)
          new_post = Post.last

          expect(new_post.raw).to eq(I18n.t('discourse_narrative_bot.narratives.hello.message_1',
            username: user.username, title: SiteSetting.title
          ).chomp)

          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym)
            .to eq(:waiting_reply)
        end
      end
    end

    describe 'when [:begin, :reply]' do
      it 'should create the right post' do
        Timecop.freeze(Time.new(2016, 10, 31, 16, 30)) do
          post.update_attributes!(
            raw: '@discobot Lets us get this started!'
          )

          narrative.input(:reply, user, post)
          new_post = Post.last

          expect(new_post.raw).to eq(I18n.t('discourse_narrative_bot.narratives.hello.message_1',
            username: user.username, title: SiteSetting.title
          ))

          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:waiting_reply)
        end
      end

      describe 'when a post is created without mentioning the bot' do
        it 'should not create a do not understand response' do
          post

          expect { narrative.input(:reply, user, post) }.to_not change { Post.count }
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:begin)
        end
      end
    end

    describe 'when [:waiting_reply, :reply]' do
      let(:post) { Fabricate(:post, topic_id: SiteSetting.discobot_welcome_topic_id) }
      let(:other_post) { Fabricate(:post) }

      before do
        DiscourseNarrativeBot::Store.set(user.id, state: :waiting_reply)
      end

      describe 'when post is not from the right topic' do
        it 'should not do anything' do
          post
          other_post

          narrative.expects(:enqueue_timeout_job).with(user).never
          expect { narrative.input(:reply, user, other_post) }.to_not change { Post.count }
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:waiting_reply)
        end
      end

      it 'should create the right reply' do
        narrative.expects(:enqueue_timeout_job).with(user)

        narrative.input(:reply, user, post)
        new_post = Post.last

        expect(new_post.raw).to eq(I18n.t('discourse_narrative_bot.narratives.quote_user_reply',
          username: post.user.username,
          post_id: post.id,
          topic_id: post.topic.id,
          post_raw: post.raw,
          category_slug: category.slug
        ))

        data = DiscourseNarrativeBot::Store.get(user.id)

        expect(data[:state].to_sym).to eq(:tutorial_topic)
        expect(data[:last_post_id]).to eq(new_post.id)
      end
    end

    describe 'when [:tutorial_topic, :reply]' do
      let(:other_topic) { Fabricate(:topic, category: category) }
      let(:other_post) { Fabricate(:post, topic: other_topic, raw: 'This Unicorn is so fluffy!') }

      before do
        DiscourseNarrativeBot::Store.set(user.id, state: :tutorial_topic)
      end

      describe 'when post is not the first post' do
        let(:other_post) { Fabricate(:post, topic: post.topic) }

        it 'should not do anything' do
          narrative.expects(:enqueue_timeout_job).with(user).never

          other_post
          expect { narrative.input(:reply, user, other_post) }.to_not change { Post.count }
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_topic)
        end
      end

      describe 'when topic is not in the right category' do
        let(:other_topic) { Fabricate(:topic) }
        let(:other_post) { Fabricate(:post, topic: other_topic) }

        it 'should not do anything' do
          narrative.expects(:enqueue_timeout_job).with(user).never

          post
          other_post

          expect { narrative.input(:reply, user, other_post) }.to_not change { Post.count }
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_topic)
        end
      end

      it 'should create the right reply' do
        narrative.expects(:enqueue_timeout_job).with(user)
        narrative.input(:reply, user, other_post)
        new_post = Post.last

        expected_raw = <<~RAW
          #{I18n.t('discourse_narrative_bot.narratives.unicorn')}

          #{I18n.t('discourse_narrative_bot.narratives.onebox.instructions')}
        RAW

        expect(new_post.raw).to eq(expected_raw.chomp)

        data = DiscourseNarrativeBot::Store.get(user.id)

        expect(data[:state].to_sym).to eq(:tutorial_onebox)
        expect(data[:last_post_id]).to eq(new_post.id)
      end
    end

    describe 'when [:tutorial_onebox, :reply]' do
      before do
        DiscourseNarrativeBot::Store.set(user.id, state: :tutorial_onebox, topic_id: topic.id)
      end

      describe 'when post is not in the right topic' do
        it 'should not do anyting' do
          other_post
          narrative.expects(:enqueue_timeout_job).with(user).never

          expect { narrative.input(:reply, user, other_post) }.to_not change { Post.count }
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_onebox)
        end
      end

      describe 'when post does not contain onebox' do
        it 'should create the right reply' do
          narrative.expects(:enqueue_timeout_job).with(user)
          narrative.input(:reply, user, post)
          new_post = Post.last

          expect(new_post.raw).to eq(I18n.t('discourse_narrative_bot.narratives.onebox.not_found'))
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_onebox)
        end
      end

      it 'should create the right reply' do
        post.update_attributes!(raw: 'https://en.wikipedia.org/wiki/ROT13')

        narrative.expects(:enqueue_timeout_job).with(user)
        narrative.input(:reply, user, post)
        new_post = Post.last

        expected_raw = <<~RAW
          #{I18n.t('discourse_narrative_bot.narratives.onebox.reply')}

          #{I18n.t('discourse_narrative_bot.narratives.images.instructions')}
        RAW

        expect(new_post.raw).to eq(expected_raw.chomp)
        expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_images)
      end
    end

    describe 'when [:tutorial_images, :reply]' do
      before do
        DiscourseNarrativeBot::Store.set(user.id, state: :tutorial_images, topic_id: topic.id)
      end

      describe 'when post is not in the right topic' do
        it 'should not do anything' do
          other_post
          narrative.expects(:enqueue_timeout_job).with(user).never

          expect { narrative.input(:reply, user, other_post) }.to_not change { Post.count }
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_images)
        end
      end

      describe 'when post does not contain an image' do
        it 'should create the right reply' do
          narrative.expects(:enqueue_timeout_job).with(user)
          narrative.input(:reply, user, post)

          expect(Post.last.raw).to eq(I18n.t('discourse_narrative_bot.narratives.images.not_found'))
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_images)
        end
      end

      it 'should create the right reply' do
        post.update_attributes!(
          raw: "<img src='https://i.ytimg.com/vi/tntOCGkgt98/maxresdefault.jpg'>",
        )

        narrative.expects(:enqueue_timeout_job).with(user)
        narrative.input(:reply, user, post)
        new_post = Post.last

        expected_raw = <<~RAW
          #{I18n.t('discourse_narrative_bot.narratives.images.reply')}

          #{I18n.t('discourse_narrative_bot.narratives.formatting.instructions')}
        RAW

        expect(new_post.raw).to eq(expected_raw.chomp)
        expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_formatting)
      end
    end

    describe 'when [:tutorial_formatting, :reply]' do
      before do
        DiscourseNarrativeBot::Store.set(user.id, state: :tutorial_formatting, topic_id: topic.id)
      end

      describe 'when post is not in the right topic' do
        it 'should not do anything' do
          other_post
          narrative.expects(:enqueue_timeout_job).with(user).never

          expect { narrative.input(:reply, user, other_post) }.to_not change { Post.count }
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_formatting)
        end
      end

      describe 'when post does not contain any formatting' do
        it 'should create the right reply' do
          narrative.expects(:enqueue_timeout_job).with(user)
          narrative.input(:reply, user, post)

          expect(Post.last.raw).to eq(I18n.t('discourse_narrative_bot.narratives.formatting.not_found'))
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_formatting)
        end
      end

      it 'should create the right reply' do
        post.update_attributes!(raw: "**bold** __italic__")

        narrative.expects(:enqueue_timeout_job).with(user)
        narrative.input(:reply, user, post)
        new_post = Post.last

        expected_raw = <<~RAW
          #{I18n.t('discourse_narrative_bot.narratives.formatting.reply')}

          #{I18n.t('discourse_narrative_bot.narratives.quoting.instructions')}
        RAW

        expect(new_post.raw).to eq(expected_raw.chomp)
        expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_quote)
      end
    end

    describe 'when [:tutorial_quote, :reply]' do
      before do
        DiscourseNarrativeBot::Store.set(user.id, state: :tutorial_quote, topic_id: topic.id)
      end

      describe 'when post is not in the right topic' do
        it 'should not do anything' do
          other_post
          narrative.expects(:enqueue_timeout_job).with(user).never

          expect { narrative.input(:reply, user, other_post) }.to_not change { Post.count }
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_quote)
        end
      end

      describe 'when post does not contain any quotes' do
        it 'should create the right reply' do
          narrative.expects(:enqueue_timeout_job).with(user)
          narrative.input(:reply, user, post)

          expect(Post.last.raw).to eq(I18n.t('discourse_narrative_bot.narratives.quoting.not_found'))
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_quote)
        end
      end

      it 'should create the right reply' do
        post.update_attributes!(
          raw: '[quote="#{post.user}, post:#{post.post_number}, topic:#{topic.id}"]\n:monkey: :fries:\n[/quote]'
        )

        narrative.expects(:enqueue_timeout_job).with(user)
        narrative.input(:reply, user, post)
        new_post = Post.last

        expected_raw = <<~RAW
          #{I18n.t('discourse_narrative_bot.narratives.quoting.reply')}

          #{I18n.t('discourse_narrative_bot.narratives.emoji.instructions')}
        RAW

        expect(new_post.raw).to eq(expected_raw.chomp)
        expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_emoji)
      end
    end

    describe 'when [:tutorial_emoji, :reply]' do
      before do
        DiscourseNarrativeBot::Store.set(user.id, state: :tutorial_emoji, topic_id: topic.id)
      end

      describe 'when post is not in the right topic' do
        it 'should not do anything' do
          other_post
          narrative.expects(:enqueue_timeout_job).with(user).never

          expect { narrative.input(:reply, user, other_post) }.to_not change { Post.count }
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_emoji)
        end
      end

      describe 'when post does not contain any emoji' do
        it 'should create the right reply' do
          narrative.expects(:enqueue_timeout_job).with(user)
          narrative.input(:reply, user, post)

          expect(Post.last.raw).to eq(I18n.t('discourse_narrative_bot.narratives.emoji.not_found'))
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_emoji)
        end
      end

      it 'should create the right reply' do
        post.update_attributes!(
          raw: ':monkey: :fries:'
        )

        narrative.expects(:enqueue_timeout_job).with(user)
        narrative.input(:reply, user, post)
        new_post = Post.last

        expected_raw = <<~RAW
          #{I18n.t('discourse_narrative_bot.narratives.emoji.reply')}

          #{I18n.t('discourse_narrative_bot.narratives.mention.instructions')}
        RAW

        expect(new_post.raw).to eq(expected_raw.chomp)
        expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_mention)
      end
    end

    describe 'when [:tutorial_mention, :reply]' do
      before do
        DiscourseNarrativeBot::Store.set(user.id, state: :tutorial_mention, topic_id: topic.id)
      end

      describe 'when post is not in the right topic' do
        it 'should not do anything' do
          other_post
          narrative.expects(:enqueue_timeout_job).with(user).never

          expect { narrative.input(:reply, user, other_post) }.to_not change { Post.count }
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_mention)
        end
      end

      describe 'when post does not contain any mentions' do
        it 'should create the right reply' do
          narrative.expects(:enqueue_timeout_job).with(user)
          narrative.input(:reply, user, post)

          expect(Post.last.raw).to eq(I18n.t(
            'discourse_narrative_bot.narratives.mention.not_found',
            username: user.username
          ))

          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_mention)
        end
      end

      it 'should create the right reply' do
        post.update_attributes!(
          raw: '@discobot hello how are you doing today?'
        )

        narrative.expects(:enqueue_timeout_job).with(user)
        narrative.input(:reply, user, post)
        new_post = Post.last

        expected_raw = <<~RAW
          #{I18n.t('discourse_narrative_bot.narratives.mention.reply')}

          #{I18n.t('discourse_narrative_bot.narratives.link.instructions', topic_id: SiteSetting.discobot_welcome_topic_id)}
        RAW

        expect(new_post.raw).to eq(expected_raw.chomp)
        expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_link)
      end
    end

    describe 'when [:tutorial_link, :reply]' do
      before do
        DiscourseNarrativeBot::Store.set(user.id, state: :tutorial_link, topic_id: topic.id)
      end

      describe 'when post is not in the right topic' do
        it 'should not do anything' do
          other_post
          narrative.expects(:enqueue_timeout_job).with(user).never

          expect { narrative.input(:reply, user, other_post) }.to_not change { Post.count }
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_link)
        end
      end

      describe 'when post does not contain any quotes' do
        it 'should create the right reply' do
          narrative.expects(:enqueue_timeout_job).with(user)
          narrative.input(:reply, user, post)

          expect(Post.last.raw).to eq(I18n.t(
            'discourse_narrative_bot.narratives.link.not_found',
            topic_id: SiteSetting.discobot_welcome_topic_id
          ))

          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_link)
        end
      end

      it 'should create the right reply' do
        pending "somehow it isn't oneboxed in tests"

        post.update_attributes!(
          raw: 'https://try.discourse.org/t/something-to-say/485'
        )

        narrative.expects(:enqueue_timeout_job).with(user)
        narrative.input(:reply, user, post)
        new_post = Post.last

        expected_raw = <<~RAW
          #{I18n.t('discourse_narrative_bot.narratives.link.reply')}
          #{I18n.t('discourse_narrative_bot.narratives.pm.instructions')}
        RAW

        expect(new_post.raw).to eq(expected_raw.chomp)
        expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_pm)
      end
    end

    describe 'when [:tutorial_pm, :reply]' do
      before do
        DiscourseNarrativeBot::Store.set(user.id, state: :tutorial_pm, topic_id: topic.id)
      end

      describe 'when post is not a PM' do
        it 'should not do anything' do
          post

          expect { narrative.input(:reply, user, post) }.to_not change { Post.count }
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_pm)
        end
      end

      describe 'when post is not a PM to bot' do
        let(:other_post) { Fabricate(:private_message_post) }

        it 'should not do anything' do
          other_post
          expect { narrative.input(:reply, user, other_post) }.to_not change { Post.count }
          expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:tutorial_pm)
        end
      end

      it 'should send a PM to the user' do
        post = Fabricate(:private_message_post, user: user)
        post.topic.allowed_users << User.find(-2)

        expect { narrative.input(:reply, user, post) }.to change { Post.count }.by(2)

        pm_post = Post.offset(1).last
        end_post = Post.last

        expect(pm_post.raw).to eq(I18n.t('discourse_narrative_bot.narratives.pm.message'))

        expect(end_post.raw).to eq(I18n.t(
          'discourse_narrative_bot.narratives.end.message',
          username: user.username,
          category_slug: category.slug
        ))

        expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:end)
      end
    end

    describe ':end state' do
      before do
        DiscourseNarrativeBot::Store.set(user.id, state: :end, topic_id: topic.id)
      end

      it 'should raise the right error when reply is not in the right topic' do
        expect { narrative.input(:reply, user, other_post) }.to raise_error(
          described_class::TransitionError
        )
      end

      it 'should create the right generic do not understand responses' do
        narrative.input(:reply, user, post)

        expect(Post.last.raw).to eq(I18n.t(
          'discourse_narrative_bot.narratives.do_not_understand.first_response'
        ))

        expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:end)

        narrative.input(:reply, user, Fabricate(:post, topic: topic))


        expect(Post.last.raw).to eq(I18n.t(
          'discourse_narrative_bot.narratives.do_not_understand.second_response'
        ))

        expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:end)

        new_post = Fabricate(:post, topic: topic)

        expect { narrative.input(:reply, user, new_post) }.to_not change { Post.count }

        expect(DiscourseNarrativeBot::Store.get(user.id)[:state].to_sym).to eq(:end)
      end
    end
  end
end
