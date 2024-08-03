# frozen_string_literal: true

module SearchMultilingualExtension
  def posts_query(limit, type_filter: nil, aggregate_search: false)
    posts = super(limit, type_filter: type_filter, aggregate_search: aggregate_search)

    if Multilingual::ContentLanguage.topic_filtering_enabled
      user = @guardian.user

      existing_tags_bare_sql =
        "(select tag_id from topic_tags where topic_tags.topic_id = posts.topic_id)"
      content_language_tag_ids_sql = <<~SQL
        (
          select t.id
          from user_custom_fields ucf
          inner join tags t
          on ucf.value = t.name
          where ucf.name = 'content_languages' and ucf.user_id = #{user.id}
        )
      SQL

      content_languages_filter =
        "exists (#{content_language_tag_ids_sql} intersect #{existing_tags_bare_sql})"

      posts = posts.where(content_languages_filter)
    end

    posts
  end
end
