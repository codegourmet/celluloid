require 'thread'

module Celluloid
  # Celluloid::Future objects allow methods and blocks to run in the
  # background, their values requested later
  class Future
    def self.new(*args, &block)
      return super unless block

      future = new
      Celluloid::ThreadHandle.new(Celluloid.actor_system, :future) do
        begin
          call = SyncCall.new(future, :call, args)
          call.dispatch(block)
        rescue
          # Exceptions in blocks will get raised when the value is retrieved
        end
      end
      future
    end

    attr_reader :address

    def initialize(&block)
      @address = Celluloid.uuid
      @mutex = Mutex.new
      @ready = false
      @result = nil
      @forwards = nil
      @cancelled = false

      if block
        @call = SyncCall.new(self, :call, args)
        Celluloid.internal_pool.get do
          begin
            @call.dispatch(block)
          rescue
            # Exceptions in blocks will get raised when the value is retrieved
          end
        end
      else
        @call = nil
      end
    end

    # Execute the given method in future context
    def execute(receiver, method, args, block)
      @mutex.synchronize do
        raise "already calling" if @call
        @call = SyncCall.new(self, method, args, block)
      end

      receiver << @call
    end

    # Check if this future has a value yet
    def ready?
      @ready
    end

    # Obtain the value for this Future
    def value(timeout = nil)
      ready = result = nil

      begin
        @mutex.lock

        if @ready
          ready = true
          result = @result
        else
          case @forwards
          when Array
            @forwards << Celluloid.mailbox
          when NilClass
            @forwards = Celluloid.mailbox
          else
            @forwards = [@forwards, Celluloid.mailbox]
          end
        end
      ensure
        @mutex.unlock
      end

      unless ready
        result = Celluloid.receive(timeout) do |msg|
          msg.is_a?(Future::Result) && msg.future == self
        end
      end

      if result
        result.value
      else
        raise TimeoutError, "Timed out"
      end
    end
    alias_method :call, :value

    # Signal this future with the given result value
    def signal(value)
      return if @cancelled
      result = Result.new(value, self)

      @mutex.synchronize do
        raise "the future has already happened!" if @ready

        if @forwards
          @forwards.is_a?(Array) ? @forwards.each { |f| f << result } : @forwards << result
        end

        @result = result
        @ready = true
      end
    end
    alias_method :<<, :signal

    def cancel(error)
      response = ErrorResponse.new(@call, error)
      signal response
      @mutex.synchronize do
        @cancelled = true
      end
    end

    # Inspect this Celluloid::Future
    alias_method :inspect, :to_s

    # Wrapper for result values to distinguish them in mailboxes
    class Result
      attr_reader :future

      def initialize(result, future)
        @result, @future = result, future
      end

      def value
        @result.value
      end
    end
  end
end