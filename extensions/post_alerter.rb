# frozen_string_literal: true
module PostAlerterMultilingualExtension
  # This is mostly taken from Discourse
  COLLAPSED_NOTIFICATION_TYPES ||= [
    Notification.types[:replied],
    Notification.types[:posted],
    Notification.types[:private_message],
    Notification.types[:watching_category_or_tag],
  ]

  NOTIFIABLE_TYPES =
    %i[
      mentioned
      replied
      quoted
      posted
      linked
      private_message
      group_mentioned
      watching_first_post
      watching_category_or_tag
      event_reminder
      event_invitation
    ].map { |t| Notification.types[t] }

  def create_notification(user, type, post, opts = {})

    opts = @default_opts.merge(opts)

    DiscourseEvent.trigger(:before_create_notification, user, type, post, opts)

    return if user.blank? || user.bot? || post.blank?
    return if (topic = post.topic).blank?

    is_liked = type == Notification.types[:liked]
    if is_liked &&
         user.user_option.like_notification_frequency ==
           UserOption.like_notification_frequency_type[:never]
      return
    end

    return if !Guardian.new(user).can_receive_post_notifications?(post)

    return if user.staged? && topic.category&.mailinglist_mirror?

    notifier_id = opts[:user_id] || post.user_id # xxxxx look at revision history
    if notifier_id &&
         UserCommScreener.new(
           acting_user_id: notifier_id,
           target_user_ids: user.id,
         ).ignoring_or_muting_actor?(user.id)
      return
    end

    # skip if muted on the topic
    if TopicUser.where(
         topic: topic,
         user: user,
         notification_level: TopicUser.notification_levels[:muted],
       ).exists?
      return
    end

    # skip if muted on the group
    if group = opts[:group]
      if GroupUser.where(
           group_id: opts[:group_id],
           user_id: user.id,
           notification_level: TopicUser.notification_levels[:muted],
         ).exists?
        return
      end
    end

    # skip if the topic is in a language not in the user's list of content
    # languages
    if Multilingual::ContentLanguage.topic_filtering_enabled
      if user.content_languages.present? &&
         user.content_languages.any? &&
         ! topic.tags.exists?(['name in (?)', user.content_languages])
        return
      end
    end

    existing_notifications =
      user
        .notifications
        .order("notifications.id DESC")
        .where(topic_id: post.topic_id, post_number: post.post_number)
        .limit(10)

    # Don't notify the same user about the same type of notification on the same post
    existing_notification_of_same_type =
      existing_notifications.find { |n| n.notification_type == type }

    if existing_notification_of_same_type &&
         !should_notify_previous?(user, post, existing_notification_of_same_type, opts)
      return
    end

    # linked, quoted, mentioned, chat_quoted may be suppressed if you already have a reply notification
    if [
         Notification.types[:quoted],
         Notification.types[:linked],
         Notification.types[:mentioned],
         Notification.types[:chat_quoted],
       ].include?(type)
      if existing_notifications.find { |n| n.notification_type == Notification.types[:replied] }
        return
      end
    end

    collapsed = false

    if COLLAPSED_NOTIFICATION_TYPES.include?(type)
      destroy_notifications(user, COLLAPSED_NOTIFICATION_TYPES, topic)
      collapsed = true
    end

    original_post = post
    original_username = opts[:display_username].presence || post.username

    if collapsed
      post = first_unread_post(user, topic) || post
      count = unread_count(user, topic)
      if count > 1
        I18n.with_locale(user.effective_locale) do
          opts[:display_username] = I18n.t("embed.replies", count: count)
        end
      end
    end

    UserActionManager.notification_created(original_post, user, type, opts[:acting_user_id])

    topic_title = topic.title
    # when sending a private message email, keep the original title
    if topic.private_message? && modifications = post.revisions.map(&:modifications)
      if first_title_modification = modifications.find { |m| m.has_key?("title") }
        topic_title = first_title_modification["title"][0]
      end
    end

    notification_data = {
      topic_title: topic_title,
      original_post_id: original_post.id,
      original_post_type: original_post.post_type,
      original_username: original_username,
      revision_number: opts[:revision_number],
      display_username: opts[:display_username] || post.user.username,
    }

    opts[:custom_data].each { |k, v| notification_data[k] = v } if opts[:custom_data].is_a?(Hash)

    if group = opts[:group]
      notification_data[:group_id] = group.id
      notification_data[:group_name] = group.name
    end

    if opts[:skip_send_email_to]&.include?(user.email)
      skip_send_email = true
    elsif original_post.via_email && (incoming_email = original_post.incoming_email)
      skip_send_email =
        incoming_email.to_addresses_split.include?(user.email) ||
          incoming_email.cc_addresses_split.include?(user.email)
    else
      skip_send_email = opts[:skip_send_email]
    end

    # Create the notification
    notification_data =
      DiscoursePluginRegistry.apply_modifier(:notification_data, notification_data)

    created =
      user.notifications.consolidate_or_create!(
        notification_type: type,
        topic_id: post.topic_id,
        post_number: post.post_number,
        post_action_id: opts[:post_action_id],
        data: notification_data.to_json,
        skip_send_email: skip_send_email,
      )

    if created.id && existing_notifications.empty? && NOTIFIABLE_TYPES.include?(type)
      create_notification_alert(
        user: user,
        post: original_post,
        notification_type: type,
        username: original_username,
        group_name: group&.name,
      )
    end

    created.id ? created : nil
  end
end
