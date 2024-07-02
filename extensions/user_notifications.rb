# frozen_string_literal: true
module UserNotificationsMultilingualExtension
  def user_posted(user, opts)
    post = opts[:post]
    topic = post.topic

    should_send =
      ! Multilingual::ContentLanguage.topic_filtering_enabled ||
      ! (user.content_languages.present? && user.content_languages.any?) ||
      topic.tags.exists?(['name in (?)', user.content_languages])

    if should_send
      opts[:allow_reply_by_email] = true
      opts[:use_site_subject] = true
      opts[:add_re_to_subject] = true
      opts[:show_category_in_subject] = true
      opts[:show_tags_in_subject] = true
      notification_email(user, opts)
    end
  end
end
