require 'resque/failure/multiple'
require 'resque/plugins/retry/log_formatting'

module Resque
  module Failure

    # A multiple failure backend, with retry suppression
    #
    # For example: if you had a job that could retry 5 times, your failure 
    # backends are not notified unless the _final_ retry attempt also fails.
    #
    # Example:
    #
    #   require 'resque-retry'
    #   require 'resque/failure/redis'
    #
    #   Resque::Failure::MultipleWithRetrySuppression.classes = [Resque::Failure::Redis]
    #   Resque::Failure.backend = Resque::Failure::MultipleWithRetrySuppression
    #
    class MultipleWithRetrySuppression < Multiple
      include Resque::Plugins::Retry::LogFormatting
      # Called when the job fails
      #
      # If the job will retry, suppress the failure from the other backends.
      # Store the lastest failure information in redis, used by the web
      # interface.
      #
      # @api private
      def save
        log "save", payload, exception

        if !(retryable? && retrying?)
          log "!(#{retryable?} && #{retryable? && retrying?}) - sending failure to superclass", payload, exception
          cleanup_retry_failure_log!
          super
        elsif retry_delay > 0
          log "retry_delay: #{retry_delay} > 0 - saving details for resque-web", payload, exception
          data = {
            :failed_at => Time.now.strftime("%Y/%m/%d %H:%M:%S"),
            :payload   => payload,
            :exception => exception.class.to_s,
            :error     => exception.to_s,
            :backtrace => Array(exception.backtrace),
            :worker    => worker.to_s,
            :queue     => queue
          }

          Resque.redis.setex(failure_key, 2*retry_delay, Resque.encode(data))
        else
          log "retry_delay: #{retry_delay} <= 0 - ignoring", payload, exception
        end
      end

      # Expose this for the hook's use
      #
      # @api public
      def self.failure_key(retry_key)
        'failure-' + retry_key
      end

      protected

      # Return the class/module of the failed job.
      def klass
        Resque::Job.new(nil, nil).constantize(payload['class'])
      end

      def retry_delay
        klass.retry_delay
      end

      def retry_key
        klass.redis_retry_key(*payload['args'])
      end

      def failure_key
        self.class.failure_key(retry_key)
      end

      def retryable?
        klass.respond_to?(:redis_retry_key)
      rescue NameError
        false
      end

      def retrying?
        Resque.redis.exists(retry_key)
      end

      def cleanup_retry_failure_log!
        Resque.redis.del(failure_key) if retryable?
      end

      def log(message,payload=nil,exception=nil)
        if Resque.logger
          args = (payload || {})['args']
          Resque.logger.info format_message(message,args,exception)
        else
          super(message)
        end
      end
    end
  end
end
