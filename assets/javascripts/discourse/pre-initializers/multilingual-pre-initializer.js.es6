import { withPluginApi } from "discourse/lib/plugin-api";
import { NotificationLevels } from "discourse/lib/notification-levels";

export default {
  name: "multilingual",
  before: "inject-discourse-objects",

  initialize(container) {
    withPluginApi("1.28.0", (api) => {
      function matchContentLanguages(topic) {
        const topicTags = new Set(topic.tags);
        const user = api.getCurrentUser();
        const userContentLanguages =
          new Set(user.get("content_languages")
          .filter(x => !Object.hasOwn(x, "icon"))
          .map(x => x.locale));

        return !userContentLanguages.isDisjointFrom(topicTags);
      }

      function isUnseen(topic) {
        return !topic.is_seen;
      }

      function isNew(topic) {
        return (
          topic.last_read_post_number === null &&
          ((topic.notification_level !== 0 && !topic.notification_level) ||
            topic.notification_level >= NotificationLevels.TRACKING) &&
          topic.created_in_new_period &&
          isUnseen(topic) &&
          matchContentLanguages(topic)
        );
      }

      function isUnread(topic) {
        return (
          topic.last_read_post_number !== null &&
          topic.last_read_post_number < topic.highest_post_number &&
          topic.notification_level >= NotificationLevels.TRACKING &&
          matchContentLanguages(topic)
        );
      }

      function isNewOrUnread(topic) {
        return isUnread(topic) || isNew(topic);
      }

      api.modifyClass("model:topic-tracking-state", {
        pluginId: "discourse-multilingual",

        _trackedTopics(opts = {}) {
          return Array.from(this.states.values())
            .map((topic) => {
              let newTopic = isNew(topic);
              let unreadTopic = isUnread(topic);
              if (newTopic || unreadTopic || opts.includeAll) {
                return { topic, newTopic, unreadTopic };
              }
            })
            .compact();
        },

        _correctMissingState(list, filter) {
          const ids = {};
          list.topics.forEach((topic) => (ids[this._stateKey(topic.id)] = true));

          for (let topicKey of this.states.keys()) {
            // if the topic is already in the list then there is
            // no compensation needed; we already have latest state
            // from the backend
            if (ids[topicKey]) {
              return;
            }

            const newState = { ...this.findState(topicKey) };
            if (filter === "unread" && isUnread(newState)) {
              // pretend read. if unread, the highest_post_number will be greater
              // than the last_read_post_number
              newState.last_read_post_number = newState.highest_post_number;
            }

            if (filter === "new" && isNew(newState)) {
              // pretend not new. if the topic is new, then last_read_post_number
              // will be null.
              newState.last_read_post_number = 1;
            }

            this.modifyState(topicKey, newState);
          }
        },

        notifyIncoming(data) {
          if (!this.newIncoming) {
            return;
          }

          const filter = this.filter;
          const filterCategory = this.filterCategory;
          const filterTag = this.filterTag;
          const categoryId = data.payload && data.payload.category_id;

          // if we have a filter category currently and it is not the
          // same as the topic category from the payload, then do nothing
          // because it doesn't need to be counted as incoming
          if (filterCategory && filterCategory.get("id") !== categoryId) {
            const category = categoryId && Category.findById(categoryId);
            if (
              !category ||
              category.get("parentCategory.id") !== filterCategory.get("id")
            ) {
              return;
            }
          }

          if (filterTag && !data.payload.tags?.includes(filterTag)) {
            return;
          }

          if (!matchContentLanguages(data.payload)) {
            return;
          }

          // always count a new_topic as incoming
          if (
            ["all", "latest", "new", "unseen"].includes(filter) &&
            data.message_type === "new_topic"
          ) {
            this._addIncoming(data.topic_id);
          }

          const unreadRecipients = ["all", "unread", "unseen"];
          if (this.currentUser?.new_new_view_enabled) {
            unreadRecipients.push("new");
          }
          // count an unread topic as incoming
          if (unreadRecipients.includes(filter) && data.message_type === "unread") {
            const old = this.findState(data);

            // the highest post number is equal to last read post number here
            // because the state has already been modified based on the /unread
            // messageBus message
            if (!old || old.highest_post_number === old.last_read_post_number) {
              this._addIncoming(data.topic_id);
            }
          }

          // always add incoming if looking at the latest list and a latest channel
          // message comes through
          if (filter === "latest" && data.message_type === "latest") {
            this._addIncoming(data.topic_id);
          }

          // Add incoming to the 'categories and latest topics' desktop view
          if (
            filter === "categories" &&
            data.message_type === "latest" &&
            Site.current().desktopView &&
            (this.siteSettings.desktop_category_page_style ===
              "categories_and_latest_topics" ||
              this.siteSettings.desktop_category_page_style ===
                "categories_and_latest_topics_created_date")
          ) {
            this._addIncoming(data.topic_id);
          }

          // hasIncoming relies on this count
          this.set("incomingCount", this.newIncoming.length);
        },

        countCategoryByState({
          type,
          categoryId,
          tagId,
          noSubcategories,
          customFilterFn,
        }) {
          const subcategoryIds = noSubcategories
            ? new Set([categoryId])
            : this.getSubCategoryIds(categoryId);

          const mutedCategoryIds = this.currentUser?.muted_category_ids?.concat(
            this.currentUser.indirectly_muted_category_ids
          );

          let filterFn;
          switch (type) {
            case "new":
              filterFn = isNew;
              break;
            case "unread":
              filterFn = isUnread;
              break;
            case "new_and_unread":
            case "unread_and_new":
              filterFn = isNewOrUnread;
              break;
            default:
              throw new Error(`Unknown filter type ${type}`);
          }

          return Array.from(this.states.values()).filter((topic) => {
            if (!filterFn(topic)) {
              return false;
            }

            if (categoryId && !subcategoryIds.has(topic.category_id)) {
              return false;
            }

            if (
              categoryId &&
              topic.is_category_topic &&
              categoryId !== topic.category_id
            ) {
              return false;
            }

            if (tagId && !topic.tags?.includes(tagId)) {
              return false;
            }

            if (type === "new" && mutedCategoryIds?.includes(topic.category_id)) {
              return false;
            }

            if (customFilterFn && !customFilterFn.call(this, topic)) {
              return false;
            }

            return true;
          }).length;
        },

      });
    });
  },
};
