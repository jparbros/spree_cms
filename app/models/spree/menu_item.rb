class Spree::MenuItem < ActiveRecord::Base

  has_ancestry cache_depth: true

  CACHE_PREFIX = 'spree_menu_items_'

  before_validation :set_slug, unless: Proc.new { |item| item.skip_ancestry_callbacks }
  before_validation :cache_ancestry, unless: Proc.new { |item| item.skip_ancestry_callbacks }
  after_save :drop_cached_slug, unless: Proc.new { |item| item.skip_ancestry_callbacks }

  has_many :menu_blocks, class_name: "Spree::MenuBlock", dependent: :destroy

  has_one :page, class_name: "Spree::Page", foreign_key: "spree_menu_item_id"
  belongs_to :menu, class_name: "Spree::Menu", foreign_key: "spree_menu_id"


  attr_accessible :ancestry, :css_class, :css_id, :slug, :title, :position,
    :spree_menu_id, :is_published, :is_visible_in_menu, :parent_id,
    :page_attributes

  attr_accessor :skip_ancestry_callbacks


  accepts_nested_attributes_for :page, allow_destroy: true,
    reject_if: :all_blank, update_only: true
  validates_associated :page

  validates :slug, presence: true,
    format: { with: /\A[\w-]+\z/, message: "only allows letters, numbers and hyphens" }
  validates :cached_slug, uniqueness: true, presence: true
  validates :menu, presence: true

  class << self

    def published
      where(is_published: true)
    end

    def by_cached_slug(cached_slug)
      slug = Cms.remove_spree_mount_point(cached_slug)
      where(cached_slug: slug)
    end

    def id_from_cached_slug(cached_slug)
      Rails.cache.fetch("#{CACHE_PREFIX}#{cached_slug}") do
        menu_item = published.by_cached_slug(cached_slug).first
        return menu_item ? menu_item.id : nil
      end
    end

    def arrange_as_array(options={}, hash=nil)
      hash ||= arrange(options)
      arr = []
      hash.each do |node, children|
        arr << node
        arr += arrange_as_array(options, children) unless children.nil?
      end
      arr
    end
  end

  def url
    if /^(\/|http:\/\/|https:\/\/)/ =~ self.slug
      self.slug
    else
      self.cached_slug
    end
  end

  def name_for_selects
    "#{'-' * depth} #{title}"
  end

  def possible_parents
    # NOTE: spree_menu_id may be blank. in this case, we will return an empty
    # array
    parents = self.class.where(spree_menu_id: self.spree_menu_id).arrange_as_array(order: 'slug')
    return self.new_record? ? parents : parents - self.subtree
  end

  def cache_ancestry(immediately=false)
    if self.parent
      o_s = "#{self.parent.cached_slug[1..-1]}/#{self.slug}"
    else
      o_s = self.slug
    end
    n_s = o_s
    i = 0
    q = self.class.where(cached_slug: "/#{n_s}")
    q = q.where("id <> ?", self.id) unless self.new_record?
    while q.exists?
      i += 1
      n_s = "#{o_s}-#{i}"
      q = self.class.where(cached_slug: "/#{n_s}")
      q = q.where("id <> ?", self.id) unless self.new_record?
    end
    if (immediately)
      logger.info("updating cached_slug column to /#{n_s} for ##{self.id}")
      self.update_column(:cached_slug, "/#{n_s}")
    else
      self.cached_slug = "/#{n_s}"
    end
    logger.info "\n\n"
    true
  end

  def drop_cached_slug
    logger.info "drop_cached_slug for #{self.id}\n\n"

    if self.cached_slug_changed? || self.ancestry_changed? || self.is_published_changed?

      self.reload

      # loop through the entire tree and do the same thing, skipping callbacks
      self.root.subtree.order(:position).each do |c|
        Rails.cache.delete("#{CACHE_PREFIX}#{c.cached_slug}-exists")
        Rails.cache.delete("#{CACHE_PREFIX}#{c.cached_slug}")
        c.cache_ancestry(true)
      end
    end
    logger.info "\n\n"
    true
  end

  private
  def set_slug
    logger.info "\n\nset_slug for #{self.id}\n\n\n"

    self.slug = self.slug.blank? ? self.title.parameterize : self.slug
    true
  end

end
