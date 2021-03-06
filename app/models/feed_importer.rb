require 'hyperresource'
require 'pmp'

class FeedImporter < ApplicationImporter
  attr_accessor :doc, :item, :feed, :feed_doc

  def source_name
    'feed'
  end

  def import(options={})
    super

    # expect a prx story id as an option
    if options[:feed_entry_id]
      import_entry(options[:feed_entry_id])
    elsif options[:feed_id]
      import_feed(options[:feed_id])
    end
  end

  def import_feed(feed_id)
    self.feed = Feed.find(feed_id)
    save_feed_doc(feed)
    # feed.entry_ids.each do |feed_entry_id|
    #   FeedImporter.new.import_entry(feed_entry_id)
    # end
  end

  def import_entry(feed_entry_id)
    logger.debug("import_entry: #{feed_entry_id}")

    self.item = FeedEntry.find(feed_entry_id)
    self.feed = item.feed
    self.feed_doc = find_or_save_feed_doc(feed)
    self.doc  = find_or_init_item_doc(item)

    set_series
    set_image
    set_audio

    set_attributes
    set_links
    set_tags

    doc.save
    logger.debug("import_entry: #{item.entry_id} saved as: #{doc.guid}")

    return doc
  end

  def set_tags
    logger.debug("set_tags")

    set_standard_tags(doc, item.entry_id)

    (item.keywords || '').split(',').each{|kw| add_tag_to_doc(doc, kw)}

    if item.explicit
      add_tag_to_doc(doc, 'explicit')
    end
  end

  def set_links
    logger.debug("set_links")

    add_link_to_doc(doc, 'alternate', { href: item.url })
    # add_link_to_doc(doc, 'author', { href: prx_web_link("pieces/#{story.id}") })
    # add_link_to_doc(doc, 'copyright', { href: prx_web_link("pieces/#{story.id}") })
  end

  def set_attributes
    logger.debug("set_attributes")

    doc.hreflang       = "en"
    doc.title          = item.title

    doc.teaser         = item.subtitle
    doc.description    = item.summary || strip_tags(content)
    doc.contentencoded = item.content
    doc.byline         = item.author || feed_doc.byline

    doc.published      = item.published || item.last_modified
    doc.valid          = {from: doc.published, to: (doc.published + 1000.years)}
  end

  def set_series
    logger.debug("set_series")

    return unless feed_doc

    add_link_to_doc(doc, 'collection', { href: feed_doc.href, title: feed_doc.title, rels:["urn:collectiondoc:collection:series"] })
  end

  def set_image
    logger.debug("set_image")

    return if item.image_url.blank?

    image_doc = find_or_save_image_doc(item.image_url)
    add_link_to_doc(doc, 'item', { href: image_doc.href, title: image_doc.title, rels: ['urn:collectiondoc:image'] })
  end

  def set_audio
    logger.debug("set_audio")

    audio_doc = find_or_save_audio_doc(item)
    add_link_to_doc(doc, 'item', { href: audio_doc.href, title: audio_doc.title, rels: ['urn:collectiondoc:audio'] })

  end

  def find_or_save_audio_doc(item)
    retrieve_doc('Audio', item.enclosure_url) || save_audio_doc(item)
  end

  def save_audio_doc(item)
    adoc = nil

    adoc = pmp.doc_of_type('audio')
    adoc.guid  = find_or_create_guid('Audio', item.enclosure_url)
    adoc.title = url_filename(item.enclosure_url)

    href     = item.enclosure_url
    type     = item.enclosure_type
    size     = item.enclosure_length
    duration = item.duration
    add_link_to_doc(adoc, 'enclosure', { href: href, type: type, meta: {size: size, duration: duration } })

    set_standard_tags(adoc, item.enclosure_url)

    adoc.save

    adoc
  end

  def find_or_init_item_doc(item)
    sdoc = retrieve_doc('FeedEntry', item.id)

    if !sdoc
      sdoc = pmp.doc_of_type('story')
      sdoc.guid = find_or_create_guid('FeedEntry', item.id)
    end

    sdoc
  end

  def find_or_save_feed_doc(feed)
    # puts "feed: #{feed.inspect}"
    retrieve_doc('Feed', feed.id) || save_feed_doc(feed)
  end

  def save_feed_doc(feed)
    sdoc             = pmp.doc_of_type('series')
    sdoc.guid        = find_or_create_guid('Feed', feed.id)
    sdoc.title       = feed.title

    sdoc.teaser      = feed.subtitle || feed.description
    sdoc.description = feed.summary || feed.description
    sdoc.byline      = extract_byline(feed)

    (feed.keywords || '').split(',').each{|kw| add_tag_to_doc(sdoc, kw)}

    add_link_to_doc(sdoc, 'alternate', { href: (feed.url || feed.feed_url) })

    # image
    if !feed.image_url.blank?
      image_doc = find_or_save_image_doc(feed.image_url)
      add_link_to_doc(sdoc, 'item', { href: image_doc.href, title: image_doc.title, rels: ['urn:collectiondoc:image'] })
    end

    # tags
    set_standard_tags(sdoc, feed.url)

    # save it
    sdoc.save

    sdoc
  end

  def find_or_save_image_doc(image_url)
    retrieve_doc('Image', image_url) || save_image_doc(image_url)
  end

  # retreive the image and detect features of it (height, width) ?
  def save_image_doc(image_url)
    idoc = nil

    idoc = pmp.doc_of_type('image')
    idoc.guid   = find_or_create_guid('Image', image_url)
    idoc.title  = url_filename(image_url)
    idoc.byline = ""

    href = image_url
    type = image_mime_type(url_filename(image_url))
    add_link_to_doc(idoc, 'enclosure', { href: image_url, type: type })

    set_standard_tags(idoc, image_url)

    idoc.save

    idoc
  end

  def url_filename(url)
    URI.parse(url).path.split('/').last
  end

  def image_mime_type(filename)
    ext = File.extname(filename)
    return 'image/jpeg' if ['.jpeg', '.jpe', '.jpg', '.jfif'].include?(ext)
    return 'image/gif'  if ['.gif'].include?(ext)
    return 'image/png'  if ['.png', '.x-png'].include?(ext)
    return 'image'
  end

  def extract_byline(feed)
    owners = feed.owners.collect{|o| o.name.strip }.join(', ') if (feed.owners && feed.owners.size > 0)
    owners || feed.author || feed.managing_editor
  end

  def find_or_create_guid(type, url)
    PMPGuidMapping.find_or_create_guid(source_name, type, url)
  end

end
