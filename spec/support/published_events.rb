# Records every event published during an example, while still delivering
# it, so specs can assert on what went out and how often.
module PublishedEvents
  def capture_published_events
    @published_events = []
    allow(Spree::Events).to receive(:publish).and_wrap_original do |original, name, payload = {}, metadata = {}|
      @published_events << [name, payload]
      original.call(name, payload, metadata)
    end
  end

  # @return [Array<Hash>] the payloads published under +name+
  def published(name)
    @published_events.select { |event_name, _| event_name == name }.map(&:last)
  end
end

RSpec.configure do |config|
  config.include PublishedEvents
end
