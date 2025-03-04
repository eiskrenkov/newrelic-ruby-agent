# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/newrelic-ruby-agent/blob/main/LICENSE for complete details.
# frozen_string_literal: true

require_relative '../test_helper'
require 'new_relic/agent/attributes'

class FooError < StandardError; end

class NewRelic::Agent::NoticedErrorTest < Minitest::Test
  include NewRelic::TestHelpers::Exceptions

  def setup
    @path = 'foo/bar/baz'

    nr_freeze_process_time
    @time = Process.clock_gettime(Process::CLOCK_REALTIME)

    @attributes = NewRelic::Agent::Attributes.new(NewRelic::Agent.instance.attribute_filter)
    @attributes_from_notice_error = {:user => 'params'}
  end

  def test_to_collector_array
    e = TestError.new('test exception')

    error = create_error(e)
    error.attributes.add_agent_attribute(:'request.uri',
      'http://com.google',
      NewRelic::Agent::AttributeFilter::DST_ERROR_COLLECTOR)
    error.attributes_from_notice_error = @attributes_from_notice_error

    expected = [
      (@time.to_f * 1000).round,
      @path,
      'test exception',
      'NewRelic::TestHelpers::Exceptions::TestError',
      {
        'userAttributes' => {'user' => 'params'},
        'agentAttributes' => {:'request.uri' => 'http://com.google'},
        'intrinsics' => {},
        :'error.expected' => false
      }
    ]

    assert_equal expected, error.to_collector_array
  end

  def test_to_collector_array_merges_custom_attributes_and_params
    e = TestError.new('test exception')
    @attributes.merge_custom_attributes(:custom => 'attribute')

    error = create_error(e)
    error.attributes_from_notice_error = @attributes_from_notice_error

    actual = extract_attributes(error)
    expected = {
      'userAttributes' => {
        'user' => 'params',
        'custom' => 'attribute'
      },
      'agentAttributes' => {},
      'intrinsics' => {},
      :'error.expected' => false
    }

    assert_equal expected, actual
  end

  def test_to_collector_array_includes_agent_attributes
    e = TestError.new('test exception')
    @attributes.add_agent_attribute(:agent, 'attribute', NewRelic::Agent::AttributeFilter::DST_ALL)
    error = create_error(e)

    actual = extract_attributes(error)

    assert_equal({:agent => 'attribute'}, actual['agentAttributes'])
  end

  def test_to_collector_array_includes_intrinsic_attributes
    e = TestError.new('test exception')
    @attributes.add_intrinsic_attribute(:intrinsic, 'attribute')
    error = create_error(e)

    actual = extract_attributes(error)

    assert_equal({:intrinsic => 'attribute'}, actual['intrinsics'])
  end

  def test_to_collector_array_happy_without_attribute_collections
    error = NewRelic::NoticedError.new(@path, 'BOOM')

    expected = [
      (@time.to_f * 1000).round,
      @path,
      'BOOM',
      'Error',
      {
        'userAttributes' => {},
        'agentAttributes' => {},
        'intrinsics' => {},
        :'error.expected' => false
      }
    ]

    assert_equal expected, error.to_collector_array
  end

  def test_to_collector_array_with_bad_values
    error = NewRelic::NoticedError.new(@path, nil, Rational(10, 1))
    expected = [
      10_000.0,
      @path,
      '<no message>',
      'Error',
      {
        :'error.expected' => false,
        'userAttributes' => {},
        'agentAttributes' => {},
        'intrinsics' => {}
      }
    ]

    assert_equal expected, error.to_collector_array
  end

  def test_handles_non_string_exception_messages
    e = Exception.new({:non => :string})
    error = NewRelic::NoticedError.new(@path, e, @time)

    assert_equal(String, error.message.class)
  end

  def test_strips_message_from_exceptions_in_high_security_mode
    with_config(:high_security => true) do
      e = TestError.new('test exception')
      error = NewRelic::NoticedError.new(@path, e, @time)

      assert_equal NewRelic::NoticedError::STRIPPED_EXCEPTION_REPLACEMENT_MESSAGE, error.message
    end
  end

  def test_long_message
    # yes, times 500. it's a 5000 byte string. Assuming strings are
    # still 1 byte / char.
    err = create_error(StandardError.new('1234567890' * 500))

    assert_equal 4096, err.message.length
    assert_equal ('1234567890' * 500)[0..4095], err.message
  end

  def test_permits_messages_from_allowlisted_exceptions_in_high_security_mode
    with_config(:'strip_exception_messages.allowed_classes' => 'NewRelic::TestHelpers::Exceptions::TestError') do
      e = TestError.new('allowlisted test exception')
      error = NewRelic::NoticedError.new(@path, e, @time)

      assert_equal 'allowlisted test exception', error.message
    end
  end

  def test_allowlisted_returns_nil_with_an_empty_allowlist
    with_config(:'strip_exception_messages.allowed_classes' => '') do
      assert_falsy NewRelic::NoticedError.passes_message_allowlist(TestError)
    end
  end

  def test_allowlisted_returns_nil_when_error_is_not_in_allowlist
    with_config(:'strip_exception_messages.allowed_classes' => 'YourErrorIsInAnotherCastle') do
      assert_falsy NewRelic::NoticedError.passes_message_allowlist(TestError)
    end
  end

  def test_allowlisted_is_true_when_error_is_in_allowlist
    with_config(:'strip_exception_messages.allowed_classes' => 'OtherException,NewRelic::TestHelpers::Exceptions::TestError') do
      assert_truthy NewRelic::NoticedError.passes_message_allowlist(TestError)
    end
  end

  def test_allowlisted_ignores_nonexistent_exception_types_in_allowlist
    with_config(:'strip_exception_messages.allowed_classes' => 'NonExistent::Exception,NewRelic::TestHelpers::Exceptions::TestError') do
      assert_truthy NewRelic::NoticedError.passes_message_allowlist(TestError)
    end
  end

  def test_allowlisted_is_true_when_an_exceptions_ancestor_is_allowlisted
    with_config(:'strip_exception_messages.allowed_classes' => 'NewRelic::TestHelpers::Exceptions::ParentException') do
      assert_truthy NewRelic::NoticedError.passes_message_allowlist(ChildException)
    end
  end

  def test_handles_exception_with_nil_original_exception
    e = Exception.new('Buffy FOREVER')
    e.stubs(:original_exception).returns(nil)
    error = NewRelic::NoticedError.new(@path, e, @time)

    assert_equal('Buffy FOREVER', error.message.to_s)
  end

  if defined?(Rails::VERSION::MAJOR) && Rails::VERSION::MAJOR < 5
    def test_uses_original_exception_class_name
      orig = FooError.new
      e = mock('exception', original_exception: orig)
      error = NewRelic::NoticedError.new(@path, e, @time)

      assert_equal('FooError', error.exception_class_name)
    end
  end

  def test_intrinsics_always_get_sent
    with_config(:'error_collector.attributes.enabled' => false) do
      attributes = NewRelic::Agent::Attributes.new(NewRelic::Agent.instance.attribute_filter)
      attributes.add_intrinsic_attribute(:intrinsic, 'attribute')

      error = NewRelic::NoticedError.new(@path, Exception.new('O_o'))
      error.attributes = attributes

      serialized_attributes = extract_attributes(error)

      assert_equal({:intrinsic => 'attribute'}, serialized_attributes['intrinsics'])
    end
  end

  def test_custom_attributes_sent_when_enabled
    with_config(:'error_collector.attributes.enabled' => true) do
      attributes = NewRelic::Agent::Attributes.new(NewRelic::Agent.instance.attribute_filter)
      custom_attrs = {'name' => 'Ron Burgundy', 'channel' => 4}
      attributes.merge_custom_attributes(custom_attrs)

      error = NewRelic::NoticedError.new(@path, Exception.new('O_o'))
      error.attributes = attributes

      assert_equal custom_attrs, error.custom_attributes
    end
  end

  def test_custom_attributes_not_sent_when_disabled
    with_config(:'error_collector.attributes.enabled' => false) do
      attributes = NewRelic::Agent::Attributes.new(NewRelic::Agent.instance.attribute_filter)
      custom_attrs = {'name' => 'Ron Burgundy', 'channel' => 4}
      attributes.merge_custom_attributes(custom_attrs)

      error = NewRelic::NoticedError.new(@path, Exception.new('O_o'))
      error.attributes = attributes

      assert_empty(error.custom_attributes)
    end
  end

  def test_agent_attributes_sent_when_enabled
    with_config(:'error_collector.attributes.enabled' => true) do
      attributes = NewRelic::Agent::Attributes.new(NewRelic::Agent.instance.attribute_filter)
      attributes.add_agent_attribute(:"request.headers.referer", 'http://blog.site/home', NewRelic::Agent::AttributeFilter::DST_ALL)

      error = NewRelic::NoticedError.new(@path, Exception.new('O_o'))
      error.attributes = attributes

      expected = {:"request.headers.referer" => 'http://blog.site/home'}

      assert_equal expected, error.agent_attributes
    end
  end

  def test_agent_attributes_not_sent_when_disabled
    with_config(:'error_collector.attributes.enabled' => false) do
      attributes = NewRelic::Agent::Attributes.new(NewRelic::Agent.instance.attribute_filter)
      attributes.add_agent_attribute(:"request.headers.referer", 'http://blog.site/home', NewRelic::Agent::AttributeFilter::DST_ALL)

      error = NewRelic::NoticedError.new(@path, Exception.new('O_o'))
      error.attributes = attributes

      assert_empty(error.agent_attributes)
    end
  end

  def test_error_group_can_be_read
    error_group = 'lucky tiger'
    error = NewRelic::NoticedError.new(@path, StandardError.new)
    error.instance_variable_set(:@error_group, error_group)

    assert_equal error_group, error.error_group
  end

  def test_error_group_can_be_set
    error_group = 'lucky tiger'
    error = NewRelic::NoticedError.new(@path, StandardError.new)
    error.error_group = error_group

    assert_equal error_group, error.error_group
  end

  def test_error_group_setting_ignores_empty_strings
    error = NewRelic::NoticedError.new(@path, StandardError.new)

    assert_nil error.error_group

    error.error_group = ''

    assert_nil error.error_group
  end

  def test_error_group_setting_ignores_nil
    error = NewRelic::NoticedError.new(@path, StandardError.new)
    error_group = 'lucky tiger'
    error.instance_variable_set(:@error_group, error_group)
    error.error_group = nil

    assert_equal error_group, error.error_group
  end

  def test_error_group_name_agent_attribute_is_set
    error_group = 'spicy lavender'
    error = NewRelic::NoticedError.new(@path, StandardError.new)
    error.error_group = error_group
    agent_attributes = error.agent_attributes

    assert_equal error_group, agent_attributes[:'error.group.name']
  end

  def test_noticed_errors_group_is_not_frozen
    error_group = 'mint tea'
    exception = RuntimeError.new
    noticed_error = ::NewRelic::NoticedError.new('www.mint_tea.com', exception)
    noticed_error.instance_variable_set(:@processed_attributes, {noticed_error.class::AGENT_ATTRIBUTES => {}})
    noticed_error.send(:error_group=, error_group)

    assert_equal error_group, noticed_error.agent_attributes[::NewRelic::NoticedError::AGENT_ATTRIBUTE_ERROR_GROUP]
  end

  private

  def create_error(exception = StandardError.new)
    noticed_error = NewRelic::NoticedError.new(@path, exception, @time)
    noticed_error.attributes = @attributes
    noticed_error
  end

  def extract_attributes(error)
    error.to_collector_array[4]
  end
end
