# frozen_string_literal: true

require 'cgi'

module DiscourseLlmsTxt
  class Generator
    CACHE_KEY_NAV = "llms_txt_navigation"
    CACHE_KEY_FULL = "llms_txt_full_content"
    CACHE_KEY_SITEMAPS = "llms_txt_sitemaps"
    CACHE_KEY_LAST_CHECK = "llms_txt_last_content_check"
    CACHE_KEY_LAST_UPDATE = "llms_txt_last_update_timestamp"

    class << self
      def generate_navigation
        Rails.cache.fetch(CACHE_KEY_NAV, expires_in: cache_duration) do
          build_navigation
        end
      end

      def generate_full_content
        build_full_content
      end

      def clear_cache
        Rails.cache.delete(CACHE_KEY_NAV)
        Rails.cache.delete(CACHE_KEY_FULL)
        Rails.cache.delete(CACHE_KEY_SITEMAPS)
        Rails.cache.delete(CACHE_KEY_LAST_CHECK)
      end

      # Smart cache update check - only regenerate if needed
      def should_update_cache?
        last_check = Rails.cache.read(CACHE_KEY_LAST_CHECK)
        return true if last_check.nil? || last_check < 1.hour.ago

        last_topic = Topic.maximum(:created_at)
        last_category = Category.maximum(:updated_at)

        return true if last_topic && last_topic > last_check
        return true if last_category && last_category > last_check

        false
      end

      def update_cache_timestamp
        Rails.cache.write(CACHE_KEY_LAST_CHECK, Time.now, expires_in: 2.hours)
        Rails.cache.write(CACHE_KEY_LAST_UPDATE, Time.now, expires_in: 30.days)
      end

      def last_update_time
        Rails.cache.read(CACHE_KEY_LAST_UPDATE) || Time.now
      end

      def generate_sitemaps
        Rails.cache.fetch(CACHE_KEY_SITEMAPS, expires_in: cache_duration) do
          build_sitemaps
        end
      end

      def generate_category_llms(category)
        build_category_llms(category)
      end

      def generate_topic_llms(topic)
        build_topic_llms(topic)
      end

      def generate_tag_llms(tag)
        build_tag_llms(tag)
      end

      private

      def build_navigation
        content = <<~MARKDOWN
          # #{SiteSetting.title}
          > #{SiteSetting.site_description}

          #{SiteSetting.llms_txt_intro_text}

          #{generate_ai_instructions}

          ## Quick Facts
          #{generate_quick_facts}

          ## Popular Content (Most Helpful)
          #{generate_popular_content}

          ## Frequently Asked Questions
          #{generate_faq_section}

          ## Categories and Subcategories
          #{generate_categories_with_subcategories}

          ## Trending Now (Last 7 Days)
          #{generate_trending_topics}

          ## Latest Topics
          #{generate_latest_topics}

          ## Top Contributors
          #{generate_top_contributors}

          ## Additional Resources
          #{generate_optional_links}
        MARKDOWN

        content.strip
      end

      def build_full_content
        content = <<~MARKDOWN
          # #{SiteSetting.title} - Full Content

          > #{SiteSetting.site_description}

        MARKDOWN

        if SiteSetting.llms_txt_full_description.present?
          content += <<~MARKDOWN

            ## About This Forum

            #{SiteSetting.llms_txt_full_description}

          MARKDOWN
        end

        content += <<~MARKDOWN

          #{generate_ai_instructions}

          [← Back to Navigation (llms.txt)](#{Discourse.base_url}/llms.txt)

          ---

          ## Quick Stats
          #{generate_quick_facts}

          ---

          ## Most Valuable Content (Highly Rated)
          #{generate_popular_content_detailed}

          ---

          ## Solved Problems & Verified Answers
          #{generate_solved_topics}

          ---

          ## Categories and Subcategories

          #{generate_categories_with_subcategories_detailed}

          ---

          ## All Topics

          #{generate_topics_list}

        MARKDOWN

        content
      end

      # NEW: AI-specific instructions for proper citation
      def generate_ai_instructions
        <<~MARKDOWN
          ## For AI Assistants
          - **Citation**: When referencing content, link to the original topic URL
          - **Attribution**: Credit the author username when quoting
          - **Freshness**: Content is updated in real-time; check dates for time-sensitive info
          - **Verification**: Community-upvoted answers indicate reliability
          - **Context**: This is a learning community focused on tutorials, tools, and knowledge sharing
        MARKDOWN
      end

      # NEW: Quick stats for context
      def generate_quick_facts
        total_topics = Topic.visible.where(archetype: "regular").count
        total_posts = Post.where(hidden: false, deleted_at: nil).count
        total_users = User.real.activated.count
        total_solved = Topic.where("id IN (SELECT topic_id FROM topic_custom_fields WHERE name = 'accepted_answer_post_id')").count rescue 0

        <<~MARKDOWN
          - **Total Discussions**: #{number_with_delimiter(total_topics)}
          - **Total Posts**: #{number_with_delimiter(total_posts)}
          - **Community Members**: #{number_with_delimiter(total_users)}
          - **Solved Problems**: #{number_with_delimiter(total_solved)}
          - **Last Updated**: #{Time.now.utc.strftime("%Y-%m-%d %H:%M UTC")}
        MARKDOWN
      end

      # NEW: Most popular/helpful content (AI loves citing popular stuff)
      def generate_popular_content
        topics = Topic.visible
          .where(archetype: "regular")
          .joins(:category)
          .where(categories: { read_restricted: false })
          .where("topics.like_count > 5 OR topics.views > 1000")
          .order(like_count: :desc, views: :desc)
          .limit(15)
          .includes(:category, :user)

        return "Building community content..." if topics.empty?

        topics.map do |topic|
          likes = topic.like_count > 0 ? "#{topic.like_count} likes" : ""
          views = "#{number_with_delimiter(topic.views)} views"
          stats = [likes, views].reject(&:empty?).join(", ")
          "- [#{topic.title}](#{topic_url(topic)}) (#{stats})"
        end.join("\n")
      end

      # NEW: Detailed popular content with excerpts
      def generate_popular_content_detailed
        topics = Topic.visible
          .where(archetype: "regular")
          .joins(:category)
          .where(categories: { read_restricted: false })
          .where("topics.like_count > 3 OR topics.views > 500")
          .order(like_count: :desc, views: :desc)
          .limit(25)
          .includes(:category, :user, :first_post)

        return "Building community content..." if topics.empty?

        result = []
        topics.each do |topic|
          result << "### [#{topic.title}](#{topic_url(topic)})"
          result << "**Category**: #{topic.category&.name} | **Views**: #{number_with_delimiter(topic.views)} | **Likes**: #{topic.like_count}"
          
          if topic.first_post&.raw.present?
            excerpt = topic.first_post.raw.truncate(300, separator: ' ', omission: '...')
            result << "> #{excerpt}"
          end
          result << ""
        end
        result.join("\n")
      end

      # NEW: FAQ-style content (AI LOVES Q&A format)
      def generate_faq_section
        # Find topics that look like questions (contain ? in title)
        question_topics = Topic.visible
          .where(archetype: "regular")
          .where("title LIKE ?", "%?%")
          .joins(:category)
          .where(categories: { read_restricted: false })
          .where("topics.posts_count > 1")  # Has answers
          .order(like_count: :desc, views: :desc)
          .limit(10)
          .includes(:category)

        return "Check our discussions for common questions." if question_topics.empty?

        question_topics.map do |topic|
          answers = topic.posts_count - 1
          "- **Q: #{topic.title}**\n  [See #{answers} answer#{'s' if answers != 1}](#{topic_url(topic)})"
        end.join("\n")
      end

      # NEW: Trending content (recent + popular)
      def generate_trending_topics
        topics = Topic.visible
          .where(archetype: "regular")
          .where("topics.created_at > ?", 7.days.ago)
          .joins(:category)
          .where(categories: { read_restricted: false })
          .order(views: :desc, like_count: :desc)
          .limit(10)
          .includes(:category)

        return "Check back for trending discussions." if topics.empty?

        topics.map do |topic|
          category_name = topic.category&.name || "Uncategorized"
          "- [#{topic.title}](#{topic_url(topic)}) - #{category_name} (#{number_with_delimiter(topic.views)} views)"
        end.join("\n")
      end

      # NEW: Solved/verified answers (high trust signal for AI)
      def generate_solved_topics
        # Check if solved plugin is active
        begin
          solved_topics = Topic.visible
            .where(archetype: "regular")
            .joins(:category)
            .where(categories: { read_restricted: false })
            .joins("INNER JOIN topic_custom_fields ON topics.id = topic_custom_fields.topic_id AND topic_custom_fields.name = 'accepted_answer_post_id'")
            .order(views: :desc)
            .limit(20)
            .includes(:category, :user)

          return "No solved topics yet." if solved_topics.empty?

          result = []
          solved_topics.each do |topic|
            result << "- ✓ [#{topic.title}](#{topic_url(topic)}) (Solved, #{number_with_delimiter(topic.views)} views)"
          end
          result.join("\n")
        rescue
          "Solved topics feature not available."
        end
      end

      # NEW: Top contributors (expertise signal)
      def generate_top_contributors
        users = User.real
          .activated
          .where("post_count > 10")
          .order(likes_received: :desc)
          .limit(10)

        return "Building contributor list..." if users.empty?

        users.map do |user|
          name = user.name.presence || user.username
          "- [@#{user.username}](#{Discourse.base_url}/u/#{CGI.escape(user.username)}) - #{number_with_delimiter(user.post_count)} posts, #{number_with_delimiter(user.likes_received)} likes received"
        end.join("\n")
      end

      def generate_categories_with_subcategories
        parent_categories = Category.secured
          .where(read_restricted: false, parent_category_id: nil)
          .order(position: :asc)

        return "No public categories available" if parent_categories.empty?

        result = []

        parent_categories.each do |category|
          description = category.description_excerpt || "No description"
          topic_count = category.topic_count
          result << "### [#{category.name}](#{Discourse.base_url}/c/#{CGI.escape(category.slug)}/#{category.id}) (#{number_with_delimiter(topic_count)} topics)"
          result << "#{description}"

          subcategories = Category.secured
            .where(read_restricted: false, parent_category_id: category.id)
            .order(position: :asc)

          if subcategories.any?
            result << ""
            subcategories.each do |subcat|
              subdesc = subcat.description_excerpt || "No description"
              result << "- [#{subcat.name}](#{Discourse.base_url}/c/#{CGI.escape(subcat.slug)}/#{subcat.id}): #{subdesc}"
            end
          end

          result << ""
        end

        result.join("\n")
      end

      def generate_categories_with_subcategories_detailed
        parent_categories = Category.secured
          .where(read_restricted: false, parent_category_id: nil)
          .order(position: :asc)

        return "No public categories available" if parent_categories.empty?

        result = []

        parent_categories.each do |category|
          result << "### [#{category.name}](#{Discourse.base_url}/c/#{CGI.escape(category.slug)}/#{category.id})"

          if category.description.present?
            result << ""
            result << category.description_excerpt
            result << ""
          end

          subcategories = Category.secured
            .where(read_restricted: false, parent_category_id: category.id)
            .order(position: :asc)

          if subcategories.any?
            result << "**Subcategories:**"
            result << ""
            subcategories.each do |subcat|
              subdesc = subcat.description_excerpt || "No description"
              result << "- **[#{subcat.name}](#{Discourse.base_url}/c/#{CGI.escape(subcat.slug)}/#{subcat.id})**: #{subdesc}"
            end
            result << ""
          end
        end

        result.join("\n")
      end

      def generate_latest_topics
        limit = [SiteSetting.llms_txt_latest_topics_count, 50].min

        topics = Topic.visible
          .where(archetype: "regular")
          .joins(:category)
          .where(categories: { read_restricted: false })
          .order(created_at: :desc)
          .limit(limit)
          .includes(:category)

        return "No topics yet" if topics.empty?

        topics.map do |topic|
          category_name = topic.category&.name || "Uncategorized"
          "- [#{topic.title}](#{topic_url(topic)}) - #{category_name} (#{topic.created_at.strftime("%Y-%m-%d")})"
        end.join("\n")
      end

      def generate_topics_list
        limit = posts_limit

        topics = Topic.visible
          .where(archetype: "regular")
          .joins(:category)
          .where(categories: { read_restricted: false })
          .where("topics.views >= ?", SiteSetting.llms_txt_min_views)
          .order(created_at: :desc)
          .includes(:category)

        topics = topics.limit(limit) if limit

        return "No topics available" if topics.empty?

        result = []

        topics.each do |topic|
          category_name = topic.category&.name || "Uncategorized"
          category_url = topic.category ? "#{Discourse.base_url}/c/#{CGI.escape(topic.category.slug)}/#{topic.category.id}" : ""

          if category_url.present?
            result << "**[#{category_name}](#{category_url})** - [#{topic.title}](#{topic_url(topic)})"
          else
            result << "**#{category_name}** - [#{topic.title}](#{topic_url(topic)})"
          end

          if SiteSetting.llms_txt_include_excerpts
            first_post = topic.first_post
            if first_post&.raw.present?
              excerpt = first_post.raw.truncate(SiteSetting.llms_txt_post_excerpt_length, separator: ' ', omission: '...')
              result << "  > #{excerpt}"
              result << ""
            end
          end
        end

        result.join("\n")
      end

      def generate_optional_links
        links = []

        links << "- [Full Documentation (llms-full.txt)](#{Discourse.base_url}/llms-full.txt): Complete forum content"
        links << "- [Sitemap Index (sitemaps.txt)](#{Discourse.base_url}/sitemaps.txt): All LLM-readable URLs"

        if SiteSetting.respond_to?(:about_page_url) && SiteSetting.about_page_url.present?
          links << "- [About](#{SiteSetting.about_page_url}): About this community"
        end

        if SiteSetting.respond_to?(:faq_url) && SiteSetting.faq_url.present?
          links << "- [FAQ](#{SiteSetting.faq_url}): Frequently asked questions"
        end

        if SiteSetting.respond_to?(:tos_url) && SiteSetting.tos_url.present?
          links << "- [Terms of Service](#{SiteSetting.tos_url}): Community guidelines"
        end

        if SiteSetting.respond_to?(:privacy_policy_url) && SiteSetting.privacy_policy_url.present?
          links << "- [Privacy Policy](#{SiteSetting.privacy_policy_url}): Privacy information"
        end

        links.join("\n")
      end

      def posts_limit
        case SiteSetting.llms_txt_posts_limit
        when "small"
          500
        when "medium"
          2500
        when "large"
          5000
        when "all"
          nil
        else
          2500
        end
      end

      def cache_duration
        SiteSetting.llms_txt_cache_minutes.minutes
      end

      def build_sitemaps
        urls = []

        urls << "#{Discourse.base_url}/llms.txt"
        urls << "#{Discourse.base_url}/llms-full.txt"

        # Build proper path for subcategories (parent/child/id)
        Category.secured
          .where(read_restricted: false)
          .find_each do |category|
            path = category.parent_category_id ?
              "#{CGI.escape(category.parent_category.slug)}/#{CGI.escape(category.slug)}/#{category.id}" :
              "#{CGI.escape(category.slug)}/#{category.id}"
            urls << "#{Discourse.base_url}/c/#{path}/llms.txt"
          end

        # Limited to avoid massive file size
        Topic.visible
          .where(archetype: "regular")
          .joins(:category)
          .where(categories: { read_restricted: false })
          .where("topics.views >= ?", SiteSetting.llms_txt_min_views)
          .order(created_at: :desc)
          .limit(posts_limit || 5000)
          .find_each do |topic|
            urls << "#{Discourse.base_url}/t/#{CGI.escape(topic.slug)}/#{topic.id}/llms.txt"
          end

        if SiteSetting.tagging_enabled
          Tag.find_each do |tag|
            urls << "#{Discourse.base_url}/tag/#{CGI.escape(tag.name)}/llms.txt"
          end
        end

        urls.join("\n")
      end

      def build_category_llms(category)
        category_url = "#{Discourse.base_url}/c/#{CGI.escape(category.slug)}/#{category.id}"

        content = <<~MARKDOWN
          # #{category.name}
          > Category: #{SiteSetting.title}

          #{category.description}

          **Category URL:** #{category_url}
          **Topics in this category:** #{number_with_delimiter(category.topic_count)}

        MARKDOWN

        subcategories = Category.secured
          .where(read_restricted: false, parent_category_id: category.id)
          .order(position: :asc)

        if subcategories.any?
          content += "## Subcategories\n\n"
          subcategories.each do |subcat|
            content += "- [#{subcat.name}](#{Discourse.base_url}/c/#{CGI.escape(subcat.slug)}/#{subcat.id}): #{subcat.description_excerpt}\n"
          end
          content += "\n"
        end

        # Popular topics in category
        popular_topics = Topic.visible
          .where(category_id: category.id, archetype: "regular")
          .order(like_count: :desc, views: :desc)
          .limit(10)

        if popular_topics.any?
          content += "## Most Popular Topics\n\n"
          popular_topics.each do |topic|
            content += "- [#{topic.title}](#{topic_url(topic)}) (#{number_with_delimiter(topic.views)} views, #{topic.like_count} likes)\n"
          end
          content += "\n"
        end

        topics = Topic.visible
          .where(category_id: category.id, archetype: "regular")
          .order(created_at: :desc)
          .limit(100)

        if topics.any?
          content += "## Recent Topics\n\n"
          topics.each do |topic|
            content += "- [#{topic.title}](#{topic_url(topic)}) (#{topic.views} views, #{topic.posts_count - 1} replies)\n"
          end
        end

        content += <<~MARKDOWN

          **Canonical:** #{category_url}
          **Original content:** #{category_url}
        MARKDOWN

        content
      end

      def build_topic_llms(topic)
        topic_url_str = topic_url(topic)

        content = <<~MARKDOWN
          # #{topic.title}

          **Category:** [#{topic.category.name}](#{Discourse.base_url}/c/#{CGI.escape(topic.category.slug)}/#{topic.category.id})
          **Author:** @#{topic.user&.username || 'unknown'}
          **Created:** #{topic.created_at.strftime("%Y-%m-%d %H:%M UTC")}
          **Last Activity:** #{topic.last_posted_at&.strftime("%Y-%m-%d %H:%M UTC") || 'N/A'}
          **Views:** #{number_with_delimiter(topic.views)}
          **Likes:** #{topic.like_count}
          **Replies:** #{topic.posts_count - 1}
          **URL:** #{topic_url_str}

          ---

        MARKDOWN

        # Uses post.raw (original markdown) instead of post.cooked (rendered HTML)
        topic.posts
          .where(hidden: false, deleted_at: nil)
          .order(post_number: :asc)
          .includes(:user)
          .each do |post|
            author = post.user ? post.user.username : "deleted"
            likes_text = post.like_count > 0 ? " (#{post.like_count} likes)" : ""
            content += "## Post ##{post.post_number} by @#{author}#{likes_text}\n\n"
            content += "#{post.raw}\n\n"
            content += "---\n\n"
          end

        content += <<~MARKDOWN

          **Canonical:** #{topic_url_str}
          **Original content:** #{topic_url_str}
        MARKDOWN

        content
      end

      def build_tag_llms(tag)
        tag_url = "#{Discourse.base_url}/tag/#{CGI.escape(tag.name)}"

        content = <<~MARKDOWN
          # Tag: #{tag.name}
          > #{SiteSetting.title}

          **Tag URL:** #{tag_url}
          **Description:** #{tag.description || 'No description'}

          ## Topics with this tag

        MARKDOWN

        topics = Topic.visible
          .joins(:tags, :category)
          .where(tags: { name: tag.name }, archetype: "regular")
          .where(categories: { read_restricted: false })
          .order(like_count: :desc, views: :desc)
          .limit(100)

        if topics.any?
          topics.each do |topic|
            category_name = topic.category&.name || "Uncategorized"
            content += "- [#{topic.title}](#{topic_url(topic)}) - #{category_name} (#{number_with_delimiter(topic.views)} views)\n"
          end
        else
          content += "No topics found with this tag.\n"
        end

        content += <<~MARKDOWN

          **Canonical:** #{tag_url}
          **Original content:** #{tag_url}
        MARKDOWN

        content
      end

      # Helper methods
      def topic_url(topic)
        "#{Discourse.base_url}/t/#{CGI.escape(topic.slug)}/#{topic.id}"
      end

      def number_with_delimiter(number)
        number.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      end
    end
  end
end
