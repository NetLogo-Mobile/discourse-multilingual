# frozen_string_literal: true
module MultilingualTranslatorTopicExtension
  def for_digest(user, since, opts = nil)
    topics = super(user, since, opts)

    if Multilingual::ContentLanguage.topic_filtering_enabled
      locale = I18n.locale.to_s
      content_languages = user ?
                          user.content_languages :
                          locale =~ /^zh(_[A-Z]+)?$/ ?
                          [locale] :
                          [locale, "en"].uniq

      if content_languages.present? && content_languages.any?
        topics = topics.joins(:tags).where("tags.name in (?)", content_languages)
      end
    end

    topics
  end
end
