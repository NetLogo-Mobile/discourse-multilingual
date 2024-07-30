# frozen_string_literal: true
module TopicTrackingStateMultilingualExtension
  # This is mostly taken from Discourse
  def report_raw_sql(
    user:,
    muted_tag_ids:,
    topic_id: nil,
    filter_old_unread: false,
    skip_new: false,
    skip_unread: false,
    skip_order: false,
    staff: false,
    admin: false,
    whisperer: false,
    select: nil,
    custom_state_filter: nil,
    additional_join_sql: nil
  )
    unread =
      if skip_unread
        "1=0"
      else
        unread_filter_sql(whisperer: whisperer)
      end

    filter_old_unread_sql =
      if filter_old_unread
        " topics.updated_at >= :user_first_unread_at AND "
      else
        ""
      end

    new =
      if skip_new
        "1=0"
      else
        new_filter_sql
      end

    category_topic_id_column_select =
      if SiteSetting.show_category_definitions_in_topic_lists
        ""
      else
        "c.topic_id AS category_topic_id,"
      end

    select_sql =
      select ||
        "
           DISTINCT topics.id as topic_id,
           u.id as user_id,
           topics.created_at,
           topics.updated_at,
           #{highest_post_number_column_select(whisperer)},
           last_read_post_number,
           c.id as category_id,
           #{category_topic_id_column_select}
           tu.notification_level,
           GREATEST(
              CASE
              WHEN COALESCE(uo.new_topic_duration_minutes, :default_duration) = :always THEN u.created_at
              WHEN COALESCE(uo.new_topic_duration_minutes, :default_duration) = :last_visit THEN COALESCE(
                u.previous_visit_at,u.created_at
              )
              ELSE (:now::timestamp - INTERVAL '1 MINUTE' * COALESCE(uo.new_topic_duration_minutes, :default_duration))
              END, u.created_at, :min_date
           ) AS treat_as_new_topic_start_date"

    category_filter =
      if admin
        ""
      else
        append = "OR u.admin" if !admin
        <<~SQL
          (
           NOT c.read_restricted #{append} OR c.id IN (
              SELECT c2.id FROM categories c2
              JOIN category_groups cg ON cg.category_id = c2.id
              JOIN group_users gu ON gu.user_id = :user_id AND cg.group_id = gu.group_id
              WHERE c2.read_restricted )
          ) AND
        SQL
      end

    visibility_filter =
      if staff
        ""
      else
        append = "OR u.admin OR u.moderator" if !staff
        "(topics.visible #{append}) AND"
      end

    tags_filter = ""

    if muted_tag_ids.present? &&
         %w[always only_muted].include?(SiteSetting.remove_muted_tags_from_latest)
      existing_tags_sql =
        "(select array_agg(tag_id) from topic_tags where topic_tags.topic_id = topics.id)"
      muted_tags_array_sql = "ARRAY[#{muted_tag_ids.join(",")}]"

      if SiteSetting.remove_muted_tags_from_latest == "always"
        tags_filter = <<~SQL
          NOT (
            COALESCE(#{existing_tags_sql}, ARRAY[]::int[]) && #{muted_tags_array_sql}
          ) AND
        SQL
      else # only muted
        tags_filter = <<~SQL
          NOT (
            COALESCE(#{existing_tags_sql}, ARRAY[-999]) <@ #{muted_tags_array_sql}
          ) AND
        SQL
      end
    end

    content_languages_filter = ""

    if Multilingual::ContentLanguage.topic_filtering_enabled &&
       user.content_languages.present? &&
       user.content_languages.any?

      existing_tags_bare_sql =
        "(select tag_id from topic_tags where topic_tags.topic_id = topics.id)"
      content_language_tag_ids_sql = <<~SQL
        (
          select t.id
          from user_custom_fields ucf
          inner join tags t
          on ucf.value = t.name
          where ucf.name = 'content_languages' and ucf.user_id = #{user.id}
        )
      SQL

      content_languages_filter = <<~SQL
        exists (#{content_language_tag_ids_sql} intersect #{existing_tags_bare_sql}) AND
      SQL
    end

    sql = +<<~SQL
      SELECT #{select_sql}
      FROM topics
      JOIN users u on u.id = :user_id
      JOIN user_options AS uo ON uo.user_id = u.id
      JOIN categories c ON c.id = topics.category_id
      LEFT JOIN topic_users tu ON tu.topic_id = topics.id AND tu.user_id = u.id
      #{skip_new ? "" : "LEFT JOIN dismissed_topic_users ON dismissed_topic_users.topic_id = topics.id AND dismissed_topic_users.user_id = :user_id"}
      #{additional_join_sql}
      WHERE u.id = :user_id AND
            #{filter_old_unread_sql}
            topics.archetype <> 'private_message' AND
            #{custom_state_filter ? custom_state_filter : "((#{unread}) OR (#{new})) AND"}
            #{visibility_filter}
            #{tags_filter}
            topics.deleted_at IS NULL AND
            #{category_filter}
            #{content_languages_filter}
            NOT (
              #{(skip_new && skip_unread) ? "" : "last_read_post_number IS NULL AND"}
              (
                topics.category_id IN (#{CategoryUser.muted_category_ids_query(user, include_direct: true).select("categories.id").to_sql})
                AND tu.notification_level <= #{TopicUser.notification_levels[:regular]}
              )
            )
    SQL

    sql << " AND topics.id = :topic_id" if topic_id

    sql << " ORDER BY topics.bumped_at DESC" unless skip_order

    sql
  end
end
