require 'rails_helper'

describe DiscourseNarrativeBot::TrackSelector do
  let(:user) { Fabricate(:user) }
  let(:discobot_user) { described_class.discobot_user }
  let(:narrative) { DiscourseNarrativeBot::NewUserNarrative.new }

  def random_mention_reply
    discobot_username = discobot_user.username

    end_message = <<~RAW
    #{I18n.t(
      'discourse_narrative_bot.track_selector.random_mention.tracks',
      discobot_username: discobot_username,
      default_track: DiscourseNarrativeBot::NewUserNarrative::RESET_TRIGGER,
      reset_trigger: described_class::RESET_TRIGGER,
      tracks: DiscourseNarrativeBot::NewUserNarrative::RESET_TRIGGER
    )}

    #{I18n.t(
      'discourse_narrative_bot.track_selector.random_mention.bot_actions',
      discobot_username: discobot_username,
    )}
    RAW

    end_message.chomp
  end

  describe '#select' do
    context 'in a PM with discobot' do
      let(:first_post) { Fabricate(:post, user: discobot_user) }

      let(:topic) do
        Fabricate(:private_message_topic, first_post: first_post,
          topic_allowed_users: [
            Fabricate.build(:topic_allowed_user, user: discobot_user),
            Fabricate.build(:topic_allowed_user, user: user),
          ]
        )
      end

      let(:post) { Fabricate(:post, topic: topic, user: user) }

      context 'during a tutorial track' do
        before do
          narrative.set_data(user,
            state: :tutorial_images,
            topic_id: topic.id,
            track: "DiscourseNarrativeBot::NewUserNarrative"
          )
        end

        context 'when bot is mentioned' do
          it 'should select the right track' do
            post.update!(raw: '@discobot show me what you can do')
            described_class.new(:reply, user, post_id: post.id).select
            new_post = Post.last

            expect(new_post.raw).to eq(I18n.t(
              "discourse_narrative_bot.new_user_narrative.images.not_found",
              image_url: "#{Discourse.base_url}/images/dog-walk.gif"
            ))
          end
        end

        context 'when bot is replied to' do
          it 'should select the right track' do
            post.update!(
              raw: 'show me what you can do',
              reply_to_post_number: first_post.post_number
            )

            described_class.new(:reply, user, post_id: post.id).select

            expect(Post.last.raw).to eq(I18n.t(
              "discourse_narrative_bot.new_user_narrative.images.not_found",
              image_url: "#{Discourse.base_url}/images/dog-walk.gif"
            ))

            described_class.new(:reply, user, post_id: post.id).select

            expected_raw = <<~RAW
            #{I18n.t(
              'discourse_narrative_bot.track_selector.do_not_understand.first_response',
              reset_trigger: "#{described_class::RESET_TRIGGER} #{DiscourseNarrativeBot::NewUserNarrative::RESET_TRIGGER}",
            )}

            #{I18n.t(
              'discourse_narrative_bot.track_selector.do_not_understand.track_response',
              reset_trigger: "#{described_class::RESET_TRIGGER} #{DiscourseNarrativeBot::NewUserNarrative::RESET_TRIGGER}",
              skip_trigger: described_class::SKIP_TRIGGER
            )}
            RAW

            expect(Post.last.raw).to eq(expected_raw.chomp)
          end
        end

        describe 'when user thanks the bot' do
          it 'should like the post' do
            post.update!(raw: 'thanks!')

            expect { described_class.new(:reply, user, post_id: post.id).select }
              .to change { PostAction.count }.by(1)

            post_action = PostAction.last

            expect(post_action.post).to eq(post)
            expect(post_action.post_action_type_id).to eq(PostActionType.types[:like])

            post = Post.last

            expect(Post.last).to eq(post)

            expect(DiscourseNarrativeBot::NewUserNarrative.new.get_data(user)['state'])
              .to eq(nil)
          end
        end

        context 'when reply contains a reset trigger' do
          it 'should start/reset the track' do
            post.update!(
              raw: "#{DiscourseNarrativeBot::TrackSelector::RESET_TRIGGER} #{DiscourseNarrativeBot::NewUserNarrative::RESET_TRIGGER}"
            )

            described_class.new(:reply, user, post_id: post.id).select

            expect(DiscourseNarrativeBot::NewUserNarrative.new.get_data(user)['state'])
              .to eq("tutorial_bookmark")
          end

          context 'start/reset advanced track' do
            before do
              post.update!(
                raw: "@#{discobot_user.username} #{DiscourseNarrativeBot::TrackSelector::RESET_TRIGGER} #{DiscourseNarrativeBot::AdvancedUserNarrative::RESET_TRIGGER}"
              )
            end

            context 'when new user track has not been completed' do
              it 'should not start the track' do
                described_class.new(:reply, user, post_id: post.id).select

                expect(DiscourseNarrativeBot::Store.get(user.id)['track'])
                  .to eq(DiscourseNarrativeBot::NewUserNarrative.to_s)
              end
            end

            context 'when new user track has been completed' do
              it 'should start the track' do
                BadgeGranter.grant(
                  Badge.find_by(name: DiscourseNarrativeBot::NewUserNarrative::BADGE_NAME),
                  user
                )

                described_class.new(:reply, user, post_id: post.id).select

                expect(DiscourseNarrativeBot::Store.get(user.id)['track'])
                  .to eq(DiscourseNarrativeBot::AdvancedUserNarrative.to_s)
              end
            end
          end
        end
      end

      context 'at the end of a tutorial track' do
        before do
          narrative.set_data(user,
            state: :end,
            topic_id: topic.id,
            track: "DiscourseNarrativeBot::NewUserNarrative"
          )
        end

        context 'generic replies' do
          after do
            $redis.del("#{described_class::GENERIC_REPLIES_COUNT_PREFIX}#{user.id}")
          end

          it 'should create the right generic do not understand responses' do
            described_class.new(:reply, user, post_id: post.id).select
            new_post = Post.last

            expect(new_post.raw).to eq(I18n.t(
              'discourse_narrative_bot.track_selector.do_not_understand.first_response',
              reset_trigger: "#{described_class::RESET_TRIGGER} #{DiscourseNarrativeBot::NewUserNarrative::RESET_TRIGGER}",
            ))

            described_class.new(:reply, user, post_id: Fabricate(:post,
              topic: new_post.topic,
              user: user,
              reply_to_post_number: new_post.post_number
            ).id).select

            new_post = Post.last

            expect(new_post.raw).to eq(I18n.t(
              'discourse_narrative_bot.track_selector.do_not_understand.second_response',
              reset_trigger: "#{described_class::RESET_TRIGGER} #{DiscourseNarrativeBot::NewUserNarrative::RESET_TRIGGER}",
            ))

            new_post = Fabricate(:post,
              topic: new_post.topic,
              user: user,
              reply_to_post_number: new_post.post_number
            )

            expect { described_class.new(:reply, user, post_id: new_post.id).select }
              .to_not change { Post.count }
          end
        end

        context 'when discobot is mentioned at the end of a track' do
          it 'should create the right reply' do
            post.update!(raw: 'Show me what you can do @discobot')
            described_class.new(:reply, user, post_id: post.id).select
            new_post = Post.last

            expect(new_post.raw).to eq(random_mention_reply)
          end

          context 'when user is an admin or moderator' do
            it 'should include the commands to start the advanced user track' do
              user.update!(moderator: true)
              post.update!(raw: 'Show me what you can do @discobot')
              described_class.new(:reply, user, post_id: post.id).select
              new_post = Post.last

              expect(new_post.raw).to include(
                DiscourseNarrativeBot::AdvancedUserNarrative::RESET_TRIGGER
              )
            end
          end

          describe 'when discobot is asked to roll dice' do
            before do
              narrative.set_data(user,
                state: :end,
                topic_id: topic.id
              )
            end

            it 'should create the right reply' do
              post.update!(raw: 'roll 2d1')
              described_class.new(:reply, user, post_id: post.id).select
              new_post = Post.last

              expect(new_post.raw).to eq(I18n.t(
                "discourse_narrative_bot.dice.results", results: '1, 1'
              ))
            end

            describe 'when range of dice request is too high' do
              before do
                srand(1)
              end

              it 'should create the right reply' do
                stub_request(:get, "https://www.wired.com/2016/05/mathematical-challenge-of-designing-the-worlds-most-complex-120-sided-dice")
                  .to_return(status: 200, body: "", headers: {})

                post.update!(raw: "roll 1d#{DiscourseNarrativeBot::Dice::MAXIMUM_RANGE_OF_DICE + 1}")
                described_class.new(:reply, user, post_id: post.id).select
                new_post = Post.last

                expected_raw = <<~RAW
                #{I18n.t('discourse_narrative_bot.dice.out_of_range')}

                #{I18n.t('discourse_narrative_bot.dice.results', results: '38')}
                RAW

                expect(new_post.raw).to eq(expected_raw.chomp)
              end
            end

            describe 'when number of dice to roll is too high' do
              it 'should create the right reply' do
                post.update!(raw: "roll #{DiscourseNarrativeBot::Dice::MAXIMUM_NUM_OF_DICE + 1}d1")
                described_class.new(:reply, user, post_id: post.id).select
                new_post = Post.last

                expected_raw = <<~RAW
                #{I18n.t('discourse_narrative_bot.dice.not_enough_dice', num_of_dice: DiscourseNarrativeBot::Dice::MAXIMUM_NUM_OF_DICE)}

                #{I18n.t('discourse_narrative_bot.dice.results', results: '1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1')}
                RAW

                expect(new_post.raw).to eq(expected_raw.chomp)
              end
            end

            describe 'when dice combination is invalid' do
              it 'should create the right reply' do
                post.update!(raw: "roll 0d1")
                described_class.new(:reply, user, post_id: post.id).select

                expect(Post.last.raw).to eq(I18n.t(
                  'discourse_narrative_bot.dice.invalid'
                ))
              end
            end
          end

          context 'when user has completed the new user track' do
            it 'should include the commands to start the advanced user track' do
              narrative.set_data(user,
                state: :end,
                topic_id: post.topic.id,
                track: "DiscourseNarrativeBot::NewUserNarrative",
              )

              BadgeGranter.grant(
                Badge.find_by(name: DiscourseNarrativeBot::NewUserNarrative::BADGE_NAME),
                user
              )

              post.update!(raw: 'Show me what you can do @discobot')
              described_class.new(:reply, user, post_id: post.id).select
              new_post = Post.last

              expect(new_post.raw).to include(
                DiscourseNarrativeBot::AdvancedUserNarrative::RESET_TRIGGER
              )
            end
          end
        end
      end

      context 'when in a normal PM with discobot' do
        describe 'when discobot is replied to' do
          it 'should create the right reply' do
            SiteSetting.discourse_narrative_bot_disable_public_replies = true
            post.update!(raw: 'Show me what you can do @discobot')
            described_class.new(:reply, user, post_id: post.id).select
            new_post = Post.last

            expect(new_post.raw).to eq(random_mention_reply)
          end

          it 'should not rate limit help message' do
            post.update!(raw: '@discobot')
            other_post = Fabricate(:post, raw: 'discobot', topic: post.topic)

            [post, other_post].each do |reply|
              described_class.new(:reply, user, post_id: reply.id).select
              expect(Post.last.raw).to eq(random_mention_reply)
            end
          end
        end
      end
    end

    context 'random discobot mentions' do
      let(:topic) { Fabricate(:topic) }
      let(:post) { Fabricate(:post, topic: topic, user: user) }

      describe 'when discobot public replies are disabled' do
        before do
          SiteSetting.discourse_narrative_bot_disable_public_replies = true
        end

        describe 'when discobot is mentioned' do
          it 'should not reply' do
            post.update!(raw: 'Show me what you can do @discobot')

            expect do
              described_class.new(:reply, user, post_id: post.id).select
            end.to_not change { Post.count }
          end
        end
      end

      describe 'when discobot is mentioned' do
        it 'should create the right reply' do
          post.update!(raw: 'Show me what you can do @discobot')
          described_class.new(:reply, user, post_id: post.id).select
          new_post = Post.last
          expect(new_post.raw).to eq(random_mention_reply)
        end

        describe 'rate limiting help message in public topic' do
          let(:topic) { Fabricate(:topic) }
          let(:other_post) { Fabricate(:post, raw: '@discobot show me something', topic: topic) }
          let(:post) { Fabricate(:post, topic: topic) }

          after do
            $redis.flushall
          end

          describe 'when help massage has been displayed in the last 6 hours' do
            it 'should not do anything' do
              $redis.set(
                "#{described_class::PUBLIC_DISPLAY_BOT_HELP_KEY}:#{other_post.topic_id}",
                post.post_number - 11
              )

              $redis.class.any_instance.expects(:ttl).returns(19.hours.to_i)

              user
              post.update!(raw: "Show me what you can do @discobot")

              expect { described_class.new(:reply, user, post_id: post.id).select }
                .to_not change { Post.count }
            end
          end

          describe 'when help message has not been displayed in the last 6 hours' do
            it 'should create the right reply' do
              $redis.set(
                "#{described_class::PUBLIC_DISPLAY_BOT_HELP_KEY}:#{other_post.topic_id}",
                post.post_number - 11
              )

              $redis.class.any_instance.expects(:ttl).returns(7.hours.to_i)

              user
              post.update!(raw: "Show me what you can do @discobot")

              described_class.new(:reply, user, post_id: post.id).select

              expect(Post.last.raw).to eq(random_mention_reply)
            end
          end

          describe 'when help message has been displayed in the last 10 replies' do
            it 'should not do anything' do
              described_class.new(:reply, user, post_id: other_post.id).select
              expect(Post.last.raw).to eq(random_mention_reply)

              expect($redis.get(
                "#{described_class::PUBLIC_DISPLAY_BOT_HELP_KEY}:#{other_post.topic_id}"
              ).to_i).to eq(other_post.post_number.to_i)

              user
              post.update!(raw: "Show me what you can do @discobot")

              expect do
                described_class.new(:reply, user, post_id: post.id).select
              end.to_not change { Post.count }
            end
          end
        end

        describe 'when discobot is asked to roll dice' do
          it 'should create the right reply' do
            post.update!(raw: '@discobot roll 2d1')
            described_class.new(:reply, user, post_id: post.id).select
            new_post = Post.last

            expect(new_post.raw).to eq(
              I18n.t("discourse_narrative_bot.dice.results",
              results: '1, 1'
            ))
          end

          describe 'when dice roll is requested incorrectly' do
            it 'should create the right reply' do
              post.update!(raw: 'roll 2d1 @discobot')
              described_class.new(:reply, user, post_id: post.id).select

              expect(Post.last.raw).to eq(random_mention_reply)
            end
          end

          describe 'when roll dice command is present inside a quote' do
            it 'should ignore the command' do
              user
              post.update!(raw: '[quote="Donkey, post:6, topic:1"]@discobot roll 2d1[/quote]')

              expect { described_class.new(:reply, user, post_id: post.id).select }
                .to_not change { Post.count }
            end
          end
        end

        describe 'when a quote is requested' do
          it 'should create the right reply' do
            ['@discobot quote', 'hello @discobot quote there'].each do |raw|
              DiscourseNarrativeBot::QuoteGenerator.expects(:generate).returns(
                quote: "Be Like Water", author: "Bruce Lee"
              )

              post.update!(raw: raw)
              described_class.new(:reply, user, post_id: post.id).select
              new_post = Post.last

              expect(new_post.raw).to eq(
                I18n.t("discourse_narrative_bot.track_selector.random_mention.quote",
                quote: "Be Like Water", author: "Bruce Lee"
              ))
            end
          end

          describe 'when quote is requested incorrectly' do
            it 'should create the right reply' do
              post.update!(raw: 'quote @discobot')
              described_class.new(:reply, user, post_id: post.id).select

              expect(Post.last.raw).to eq(random_mention_reply)
            end
          end

          describe 'when quote command is present inside a onebox or quote' do
            it 'should ignore the command' do
              user
              post.update!(raw: '[quote="Donkey, post:6, topic:1"]@discobot quote[/quote]')

              expect { described_class.new(:reply, user, post_id: post.id).select }
                .to_not change { Post.count }
            end
          end
        end
      end
    end

    context 'pm to self' do
      let(:other_topic) do
        topic_allowed_user = Fabricate.build(:topic_allowed_user, user: user)
        Fabricate(:private_message_topic, topic_allowed_users: [topic_allowed_user])
      end

      let(:other_post) { Fabricate(:post, topic: other_topic) }

      describe 'when a new message is made' do
        it 'should not do anything' do
          other_post

          expect { described_class.new(:reply, user, post_id: other_post.id).select }
            .to_not change { Post.count }
        end
      end
    end

    context 'pms to bot' do
      let(:other_topic) do
        topic_allowed_user = Fabricate.build(:topic_allowed_user, user: user)
        bot = Fabricate.build(:topic_allowed_user, user: discobot_user)
        Fabricate(:private_message_topic, topic_allowed_users: [topic_allowed_user, bot])
      end

      let(:other_post) { Fabricate(:post, topic: other_topic) }

      describe 'when a new like is made' do
        it 'should not do anything' do
          other_post
          expect { described_class.new(:like, user, post_id: other_post.id).select }
            .to_not change { Post.count }
        end
      end

      describe 'when a new message is made' do
        it 'should create the right reply' do
          described_class.new(:reply, user, post_id: other_post.id).select

          expect(Post.last.raw).to eq(random_mention_reply)
        end
      end

      describe 'when user thanks the bot' do
        it 'should like the post' do
          other_post.update!(raw: 'thanks!')

          expect { described_class.new(:reply, user, post_id: other_post.id).select }
            .to change { PostAction.count }.by(1)

          post_action = PostAction.last

          expect(post_action.post).to eq(other_post)
          expect(post_action.post_action_type_id).to eq(PostActionType.types[:like])
        end
      end
    end
  end
end
