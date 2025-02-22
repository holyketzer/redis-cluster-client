# frozen_string_literal: true

require 'redis_client/cluster/node/replica_mixin'

class RedisClient
  class Cluster
    class Node
      class LatencyReplica
        include ::RedisClient::Cluster::Node::ReplicaMixin

        attr_reader :replica_clients

        DUMMY_LATENCY_MSEC = 100 * 1000 * 1000
        MEASURE_ATTEMPT_COUNT = 10

        def initialize(replications, options, pool, **kwargs)
          super

          all_replica_clients = @clients.select { |k, _| @replica_node_keys.include?(k) }
          latencies = measure_latencies(all_replica_clients)
          @replications.each_value { |keys| keys.sort_by! { |k| latencies.fetch(k) } }
          @replica_clients = select_replica_clients(@replications, @clients)
          @clients_for_scanning = select_clients_for_scanning(@replications, @clients)
          @existed_replicas = @replications.values.reject(&:empty?)
        end

        def clients_for_scanning(seed: nil) # rubocop:disable Lint/UnusedMethodArgument
          @clients_for_scanning
        end

        def find_node_key_of_replica(primary_node_key, seed: nil) # rubocop:disable Lint/UnusedMethodArgument
          @replications.fetch(primary_node_key, EMPTY_ARRAY).first || primary_node_key
        end

        def any_replica_node_key(seed: nil)
          random = seed.nil? ? Random : Random.new(seed)
          @existed_replicas.sample(random: random)&.first || any_primary_node_key(seed: seed)
        end

        private

        def measure_latencies(clients)
          clients.each_slice(::RedisClient::Cluster::Node::MAX_THREADS).each_with_object({}) do |chuncked_clients, acc|
            chuncked_clients
              .map { |node_key, client| [node_key, build_thread_for_measuring_latency(client)] }
              .each { |node_key, thread| acc[node_key] = thread.value }
          end
        end

        def build_thread_for_measuring_latency(client)
          Thread.new(client) do |cli|
            min = DUMMY_LATENCY_MSEC
            MEASURE_ATTEMPT_COUNT.times do
              starting = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
              cli.call_once('PING')
              duration = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond) - starting
              min = duration if duration < min
            end

            min
          rescue StandardError
            DUMMY_LATENCY_MSEC
          end
        end

        def select_replica_clients(replications, clients)
          keys = replications.values.filter_map(&:first)
          clients.select { |k, _| keys.include?(k) }
        end

        def select_clients_for_scanning(replications, clients)
          keys = replications.map do |primary_node_key, replica_node_keys|
            replica_node_keys.empty? ? primary_node_key : replica_node_keys.first
          end

          clients.select { |k, _| keys.include?(k) }
        end
      end
    end
  end
end
