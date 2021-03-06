require 'spec_helper'
require 'support/integration_setups.rb'

describe 'Integration/SubscriberResponses' do
  context 'matches channels outside channel group' do
    it 'works' do
      ClimateControl.modify 'SKIP_RATE_LIMITING': 'true' do
        original_time = Time.now.midnight
        travel_to_time(original_time - (32.days))
        setup_user_channel_group_and_channel
        create_30_days_of_daily_simple_messages(@channel)
        @outside_channel = build :individually_scheduled_messages_channel, user: @user, tparty_keyword: @channel_group.tparty_keyword
        @outside_channel.relative_schedule = true
        @outside_channel.name = "Outside channel"
        @outside_channel.save
        @channel.name = 'Inside channel'
        @channel.save
        create_30_days_of_daily_response_messages(@outside_channel)

        # the next day, a subscriber registers and gets in channel and out of channel messages setup
        travel_to_time(original_time - 31.days)
        @subscriber = create :subscriber, user: @user
        @channel.subscribers << @subscriber
        @outside_channel.subscribers << @subscriber

        # it should not have sent a message at midnight
        expect { run_worker! }.to_not change { DeliveryNotice.count }
        base_add_time = Time.now

        [1].to_a.each do |dayz|
          travel_to_time(base_add_time + dayz.days)
          travel_to_same_day_at(11,0)
          expect { run_worker! }.to_not change { DeliveryNotice.count }

          expect {
            travel_to_same_day_at(12,00)
            run_worker!
          }.to change { DeliveryNotice.count }.by(2)

          expect {
            travel_to_same_day_at(12,30)
            send_a_subscriber_response(@subscriber, @channel_group.tparty_keyword, Faker::Lorem.sentence)
          }.to change { SubscriberResponse.count }.by(1)

          expect {
            travel_to_same_day_at(13,00)
            run_worker!
          }.to_not change { DeliveryNotice.count }

          expect {
            travel_to_same_day_at(14,00)
            run_worker!
          }.to_not change { DeliveryNotice.count }
        end

        # the next day we don't send a response, and should get reminders
        [2].each do |dayz|
          travel_to_time(base_add_time + dayz.days)
          travel_to_same_day_at(11,0)
          expect { run_worker! }.to_not change { DeliveryNotice.count }
          expect {
            travel_to_same_day_at(12,00)
            run_worker!
          }.to change { DeliveryNotice.count }.by(2)
          travel_to_same_day_at(13,00)
          expect {
            run_worker!
            travel_to_same_day_at(13,03)
            run_worker!
          }.to change { DeliveryNotice.count }.by(1)
          travel_to_same_day_at(14,00)
          expect {
            run_worker!
            travel_to_same_day_at(14,03)
            run_worker!
          }.to change { DeliveryNotice.count }.by(1)
          # its all done, it doesn't send any more reminder messages
          travel_to_same_day_at(15,20)
          expect { run_worker! }.to_not change { DeliveryNotice.count }
        end
      end
    end
  end
  context 'matches response-type messages before simple ones' do
    it 'works' do
      travel_to_string_time('January 1, 2017 10:00')
      setup_user_and_individually_scheduled_messages_relative_schedule
      channel_2 = create :random_messages_channel, user: @user
      channel_3 = create :random_messages_channel, user: @user
      channel_4 = create :random_messages_channel, user: @user
      channel_5 = create :random_messages_channel, user: @user
      rm = create :response_message, channel: @channel, schedule: 'Day 1 13:0'
      ra1 = create :response_action, message: rm, response_text: 'a'
      ra1.action.as_text = "Switch channel to #{channel_2.id}"
      ra1.action.save
      ra2 = create :response_action, message: rm, response_text: 'b'
      ra2.action.as_text = "Switch channel to #{channel_3.id}"
      ra2.action.save
      rm2 = create :response_message, channel: @channel, schedule: 'Day 1 13:30'
      ra3 = create :response_action, message: rm2, response_text: 'c'
      ra3.action.as_text = "Switch channel to #{channel_3.id}"
      ra3.action.save
      ra4 = create :response_action, message: rm2, response_text: 'd'
      ra4.action.as_text = "Switch channel to #{channel_4.id}"
      ra4.action.save
      create :message, channel: @channel, schedule: 'Day 1 14:0'
      subs = create :subscriber, user: @user
      expect { @channel.subscribers << subs }.to change { Subscription.count }.by(1)
      travel_to_string_time('January 2, 2017 13:00')
      expect { run_worker! }.to change { DeliveryNotice.count }.by(1)
      travel_to_string_time('January 2, 2017 13:30')
      expect { run_worker! }.to change { DeliveryNotice.count }.by(1)
      travel_to_string_time('January 2, 2017 14:00')
      expect { run_worker! }.to change { DeliveryNotice.count }.by(1)
      travel_to_string_time('January 2, 2017 14:30')
      expect {
        incoming_message = build :inbound_twilio_message
        incoming_message['From'] = subs.phone_number
        incoming_message['To'] = @channel.tparty_keyword
        incoming_message['Body'] = "b"
        controller = TwilioController.new.send(:handle_request, incoming_message)
      }.to change { SubscriberResponse.count }.by(1)
      expect(subs.channels.map(&:id).include?(channel_3.id)).to be_truthy
    end
  end
  # matching
  context 'matches over time' do
    it 'to most resent UNREPLIED delivery notice' do
      travel_to_string_time('January 1, 2017 10:00')
      setup_user_and_individually_scheduled_messages_relative_schedule
      channel_2 = create :individually_scheduled_messages_channel, user: @user, relative_schedule: true, tparty_keyword: @channel.tparty_keyword
      rm1 = create :response_message, channel: @channel, schedule: 'Day 1 13:0'
      rm2 = create :response_message, channel: channel_2, schedule: 'Day 1 13:30'
      expect { @channel.subscribers << @subscriber }.to change { Subscription.count }.by(1)
      expect { channel_2.subscribers << @subscriber }.to change { Subscription.count }.by(1)
      # travel to day 1 at 1pm, send message 1
      travel_to_string_time('January 2, 2017 13:00')
      expect { run_worker! }.to change { DeliveryNotice.count }.by(1)
      # and day 1 at 130, send mesage 2
      travel_to_string_time('January 2, 2017 13:31')
      expect { run_worker! }.to change { DeliveryNotice.count }.by(1)

      # send the first response to the most recent message
      expect {
        travel_to_string_time('January 2, 2017 13:34')
        send_inbound_message_from_subscriber(@subscriber, @channel.tparty_keyword, 'first response')
      }.to change {
        SubscriberResponse.count
      }.by(1)
      # send the second response
      expect {
        travel_to_string_time('January 2, 2017 13:35')
        send_inbound_message_from_subscriber(@subscriber, @channel.tparty_keyword, 'second response')
      }.to change {
        SubscriberResponse.count
      }.by(1)
      # the first response taht was sent should be matched to the SECOND mesage
      sr1 = SubscriberResponse.order(created_at: :asc)[0]
      # the sedond response message should be sent to the FIRST message
      sr2 = SubscriberResponse.order(created_at: :asc)[1]
      expect(sr1.message.id == rm2.id).to be_truthy
      expect(sr2.message.id == rm1.id).to be_truthy
    end
  end

  context 'matches using response action keys as hints' do
    it '(y.+) with yes' do
      travel_to_string_time('January 1, 2017 10:00')
      setup_user_and_individually_scheduled_messages_relative_schedule
      create :response_message, channel: @channel, schedule: 'Day 1 13:0'
      rmm = create_response_message_with_match_hint(@channel, 'Day 1 13:0', 'y.+')
      create :response_message, channel: @channel, schedule: 'Day 1 13:0'
      expect { @channel.subscribers << @subscriber }.to change { Subscription.count }.by(1)
      travel_to_string_time('January 2, 2017 13:0')
      expect { run_worker! }.to change { DeliveryNotice.count }.by(3)
      expect {
        travel_to_string_time('January 2, 2017 13:34')
        send_inbound_message_from_subscriber(@subscriber, @channel.tparty_keyword, 'yes')
      }.to change { SubscriberResponse.count }.by(1)
      expect(rmm.id == SubscriberResponse.first.message_id).to be_truthy
    end
    it '(n.+) with no' do
      travel_to_string_time('January 1, 2017 10:00')
      setup_user_and_individually_scheduled_messages_relative_schedule
      create :response_message, channel: @channel, schedule: 'Day 1 13:0'
      rmm = create_response_message_with_match_hint(@channel, 'Day 1 13:0', 'n.+')
      create_response_message_with_match_hint(@channel, 'Day 1 13:0', 'y.+')
      expect { @channel.subscribers << @subscriber }.to change { Subscription.count }.by(1)
      travel_to_string_time('January 2, 2017 13:0')
      expect { run_worker! }.to change { DeliveryNotice.count }.by(3)
      expect {
        travel_to_string_time('January 2, 2017 13:34')
        send_inbound_message_from_subscriber(@subscriber, @channel.tparty_keyword, 'no')
      }.to change { SubscriberResponse.count }.by(1)
      expect(rmm.id == SubscriberResponse.first.message_id).to be_truthy
    end
    it 'matches the string with 2 commas in it' do
      travel_to_string_time('January 1, 2017 10:00')
      setup_user_and_individually_scheduled_messages_relative_schedule
      create_response_message_with_match_hint(@channel, 'Day 1 13:0', 'no.+')
      rmm = create_response_message_with_match_hint(@channel, 'Day 1 13:0', '.+\,.+\,')
      create_response_message_with_match_hint(@channel, 'Day 1 13:0', 'y.+')
      expect { @channel.subscribers << @subscriber }.to change { Subscription.count }.by(1)
      travel_to_string_time('January 2, 2017 13:0')
      expect { run_worker! }.to change { DeliveryNotice.count }.by(3)
      expect {
        travel_to_string_time('January 2, 2017 13:34')
        send_inbound_message_from_subscriber(@subscriber, @channel.tparty_keyword, 'ate well, slept well, drank well')
      }.to change { SubscriberResponse.count }.by(1)
      expect(rmm.id == SubscriberResponse.first.message_id).to be_truthy
    end
  end
end
