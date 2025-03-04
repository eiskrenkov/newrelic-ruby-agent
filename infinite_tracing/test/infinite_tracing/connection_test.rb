# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/newrelic-ruby-agent/blob/main/LICENSE for complete details.
# frozen_string_literal: true

require_relative '../test_helper'

module NewRelic
  module Agent
    module InfiniteTracing
      class ConnectionTest < Minitest::Test
        include FakeTraceObserverHelpers

        # This scenario tests client being initialized before the agent
        # begins it's connection handshake.
        def test_connection_initialized_before_connecting
          with_serial_lock do
            with_config(localhost_config) do
              connection = Connection.instance # instantiate before simulation
              simulate_connect_to_collector(fiddlesticks_config, 0.01) do |simulator|
                simulator.join # ensure our simulation happens!
                metadata = connection.send(:metadata)

                assert_equal 'swiss_cheese', metadata['license_key']
                assert_equal 'fiddlesticks', metadata['agent_run_token']
              end
            end
          end
        end

        # This scenario tests that agent _can_ be connected before connection
        # is instantiated.
        def test_connection_initialized_after_connecting
          with_serial_lock do
            with_config(localhost_config) do
              simulate_connect_to_collector(fiddlesticks_config, 0.0) do |simulator|
                simulator.join # ensure our simulation happens!
                connection = Connection.instance # instantiate after simulated connection
                metadata = connection.send(:metadata)

                assert_equal 'swiss_cheese', metadata['license_key']
                assert_equal 'fiddlesticks', metadata['agent_run_token']
              end
            end
          end
        end

        # This scenario tests that the agent is connecting _after_
        # the client is instantiated (via sleep 0.01 w/o explicit join).
        def test_connection_initialized_after_connecting_and_waiting
          with_serial_lock do
            with_config(localhost_config) do
              simulate_connect_to_collector(fiddlesticks_config, 0.01) do |simulator|
                simulator.join # ensure our simulation happens!
                connection = Connection.instance
                metadata = connection.send(:metadata)

                assert_equal 'swiss_cheese', metadata['license_key']
                assert_equal 'fiddlesticks', metadata['agent_run_token']
              end
            end
          end
        end

        # Tests making an initial connection and then reconnecting.
        # The metadata is expected to change since agent run token changes.
        def test_connection_reconnects
          with_serial_lock do
            with_config(localhost_config) do
              connection = Connection.instance
              simulate_connect_to_collector(fiddlesticks_config, 0.0) do |simulator|
                simulator.join
                metadata = connection.send(:metadata)

                assert_equal 'swiss_cheese', metadata['license_key']
                assert_equal 'fiddlesticks', metadata['agent_run_token']

                simulate_reconnect_to_collector(reconnect_config)

                metadata = connection.send(:metadata)

                assert_equal 'swiss_cheese', metadata['license_key']
                assert_equal 'shazbat', metadata['agent_run_token']
              end
            end
          end
        end

        def test_sending_spans_to_server
          with_config('infinite_tracing.batching': false) do
            with_serial_lock do
              total_spans = 5
              spans, segments = emulate_streaming_segments(total_spans)

              assert_equal total_spans, segments.size
              assert_equal total_spans, spans.size
            end
          end
        end

        def test_handling_unimplemented_server_response
          with_config('infinite_tracing.batching': false) do
            with_serial_lock do
              total_spans = 5
              active_client = nil

              spans, segments, active_client = emulate_streaming_to_unimplemented(total_spans)

              assert_kind_of SuspendedStreamingBuffer, active_client.buffer
              assert_predicate active_client, :suspended?, 'expected client to be suspended.'

              assert_equal total_spans, segments.size
              assert_equal 0, spans.size

              assert_metrics_recorded 'Supportability/InfiniteTracing/Span/Sent'
              assert_metrics_recorded 'Supportability/InfiniteTracing/Span/Response/Error'

              assert_metrics_recorded({
                'Supportability/InfiniteTracing/Span/Seen' => {:call_count => total_spans},
                'Supportability/InfiniteTracing/Span/gRPC/UNIMPLEMENTED' => {:call_count => 1}
              })
            end
          end
        end

        def test_handling_failed_precondition_server_response
          with_config('infinite_tracing.batching': false) do
            with_serial_lock do
              total_spans = 5
              active_client = nil

              spans, segments, active_client = emulate_streaming_to_failed_precondition(total_spans)

              refute_kind_of SuspendedStreamingBuffer, active_client.buffer
              refute active_client.suspended?, 'expected client to not be suspended.'

              assert_equal total_spans, segments.size
              assert_equal 0, spans.size

              assert_metrics_recorded 'Supportability/InfiniteTracing/Span/Sent'
              assert_metrics_recorded 'Supportability/InfiniteTracing/Span/Response/Error'

              assert_metrics_recorded({
                'Supportability/InfiniteTracing/Span/Seen' => {:call_count => total_spans},
                'Supportability/InfiniteTracing/Span/gRPC/FAILED_PRECONDITION' => {:call_count => 5}
              })
            end
          end
        end

        def test_handling_ok_and_close_server_response
          with_config('infinite_tracing.batching': false) do
            with_detailed_trace do
              total_spans = 5
              expects_logging(:debug, all_of(includes('closed the stream'), includes('OK response.')), anything)

              spans, segments = emulate_streaming_with_ok_close_response(total_spans)

              assert_equal total_spans, segments.size
              assert_equal total_spans, spans.size, 'spans got dropped/discarded?'

              refute_metrics_recorded 'Supportability/InfiniteTracing/Span/Response/Error'

              assert_metrics_recorded('Supportability/InfiniteTracing/Span/Sent')
            end
          end
        end

        def test_reconnection_backoff
          with_serial_lock do
            connection = Connection.instance
            connection.stubs(:retry_connection_period).returns(0)
            connection.stubs(:note_connect_failure).returns(0).then.raises(NewRelic::TestHelpers::Exceptions::TestError) # reattempt once and then forcibly break out of with_reconnection_backoff

            attempts = 0
            begin
              connection.send(:with_reconnection_backoff) do
                attempts += 1
                raise NewRelic::TestHelpers::Exceptions::TestRuntimeError # simulate grpc raising connection error
              end
            rescue NewRelic::TestHelpers::Exceptions::TestError
              # broke out of with_reconnection_backoff method
            end

            assert_equal 2, attempts
          end
        end

        def test_metadata_includes_request_headers_map
          with_serial_lock do
            with_config(localhost_config) do
              NewRelic::Agent.agent.service.instance_variable_set(:@request_headers_map, {'NR-UtilizationMetadata' => 'test_metadata'})

              connection = Connection.instance # instantiate before simulation
              simulate_connect_to_collector(fiddlesticks_config, 0.01) do |simulator|
                simulator.join # ensure our simulation happens!
                metadata = connection.send(:metadata)

                assert_equal 'test_metadata', metadata['nr-utilizationmetadata']
              end
            end
          end
        end

        # Testing the backoff similarly to connect_test.rb
        def test_increment_retry_period
          unstub_reconnection

          assert_equal 15, next_retry_period
          assert_equal 15, next_retry_period
          assert_equal 30, next_retry_period
          assert_equal 60, next_retry_period
          assert_equal 120, next_retry_period
          assert_equal 300, next_retry_period
          assert_equal 300, next_retry_period
          assert_equal 300, next_retry_period
        end

        def test_gzip_related_parameters_exist_in_metadata_when_compression_is_enabled
          reset_compression_level

          with_serial_lock do
            with_config(localhost_config) do
              connection = Connection.instance # instantiate before simulation
              simulate_connect_to_collector(fiddlesticks_config, 0.01) do |simulator|
                simulator.join # ensure our simulation happens!
                metadata = connection.send(:metadata)

                NewRelic::Agent::InfiniteTracing::Connection::GZIP_METADATA.each do |key, value|
                  assert_equal value, metadata[key]
                end
              end
            end
          end
        end

        def test_gzip_related_parameters_are_absent_when_compression_is_disabled
          reset_compression_level

          with_serial_lock do
            with_config(localhost_config.merge({'infinite_tracing.compression_level': :none})) do
              connection = Connection.instance # instantiate before simulation
              simulate_connect_to_collector(fiddlesticks_config, 0.01) do |simulator|
                simulator.join # ensure our simulation happens!
                metadata = connection.send(:metadata)

                NewRelic::Agent::InfiniteTracing::Connection::GZIP_METADATA.each do |key, _value|
                  refute metadata.key?(key)
                end
              end
            end
          end
        end

        private

        def next_retry_period
          result = Connection.instance.send(:retry_connection_period)
          Connection.instance.send(:note_connect_failure)
          result
        end
      end
    end
  end
end
