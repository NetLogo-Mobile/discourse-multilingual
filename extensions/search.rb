# frozen_string_literal: true

module SearchMultilingualExtension
  def posts_query(limit, type_filter: nil, aggregate_search: false)
    posts = super(limit, type_filter: type_filter, aggregate_search: aggregate_search)

    if Multilingual::ContentLanguage.topic_filtering_enabled
      user = @guardian.user
      locale = I18n.locale.to_s

      existing_tags_bare_sql = <<~SQL
          (
            select tag_id
            from topic_tags
            where topic_tags.topic_id = posts.topic_id
          )
      SQL

      if user
        content_language_tag_ids_sql = <<~SQL
          (
            select t.id
            from user_custom_fields ucf
            inner join tags t
            on ucf.value = t.name
            where ucf.name = 'content_languages' and ucf.user_id = #{user.id}
          )
        SQL
      else
        locale = I18n.locale.to_s

        raise "Malformed locale" unless /^[a-z]{2}(_[A-Z]{2})?$/.match?(locale)

        content_languages = locale =~ /^zh(_[A-Z]{2})?$/ ?
                            [locale] :
                            [locale, "en"].uniq

        content_language_tag_ids_sql = <<~SQL
          (
            select id
            from tags
            where name in (#{content_languages.map{|x| "'#{x}'"}.join(",")})
          )
        SQL
      end

      content_languages_filter = <<~SQL
        exists
        (
          #{content_language_tag_ids_sql}
          intersect
          #{existing_tags_bare_sql}
        )
      SQL

      posts = posts.where(content_languages_filter)
    end

    posts
  end
end
