class MQ
  class Queue
    include AMQP
    
    def initialize mq, name, opts = {}
      @mq = mq
      @mq.queues[@name = name] ||= self
      @mq.callback{
        @mq.send Protocol::Queue::Declare.new({ :queue => name,
                                                :nowait => true }.merge(opts))
      }
    end
    attr_reader :name

    # This method binds a queue to an exchange.  Until a queue is
    # bound it will not receive any messages.  In a classic messaging
    # model, store-and-forward queues are bound to a dest exchange
    # and subscription queues are bound to a dest_wild exchange.
    #
    # A valid exchange name (or reference) must be passed as the first
    # parameter. Both of these are valid:
    #  exch = MQ.direct('foo exchange')
    #  queue = MQ.queue('bar queue')
    #  queue.bind('foo.exchange') # OR
    #  queue.bind(exch)
    #
    # It is not valid to call #bind without the +exchange+ parameter.
    #
    # It is unnecessary to call #bind when the exchange name and queue
    # name match exactly (for +direct+ and +fanout+ exchanges only).
    # There is an implicit bind which will deliver the messages from
    # the exchange to the queue.
    #
    # == Options
    # * :key => 'some string'
    # Specifies the routing key for the binding.  The routing key is
    # used for routing messages depending on the exchange configuration.
    # Not all exchanges use a routing key - refer to the specific
    # exchange documentation.  If the routing key is empty and the queue
    # name is empty, the routing key will be the current queue for the
    # channel, which is the last declared queue.
    #
    # * :nowait => true | false (default true)
    # If set, the server will not respond to the method. The client should
    # not wait for a reply method.  If the server could not complete the
    # method it will raise a channel or connection exception.
    #
    def bind exchange, opts = {}
      @mq.callback{
        @mq.send Protocol::Queue::Bind.new({ :queue => name,
                                             :exchange => exchange.respond_to?(:name) ? exchange.name : exchange,
                                             :routing_key => opts.delete(:key),
                                             :nowait => true }.merge(opts))
      }
      self
    end

    def unbind exchange, opts = {}
      @mq.callback{
        @mq.send Protocol::Queue::Unbind.new({ :queue => name,
                                               :exchange => exchange.respond_to?(:name) ? exchange.name : exchange,
                                               :routing_key => opts.delete(:key),
                                               :nowait => true }.merge(opts))
      }
      self
    end

    # This method deletes a queue.  When a queue is deleted any pending
    # messages are sent to a dead-letter queue if this is defined in the
    # server configuration, and all consumers on the queue are cancelled.
    #
    # == Options
    # * :if_unused => true | false (default false)
    # If set, the server will only delete the queue if it has no
    # consumers. If the queue has consumers the server does does not
    # delete it but raises a channel exception instead.
    #
    # * :if_empty => true | false (default false)
    # If set, the server will only delete the queue if it has no
    # messages. If the queue is not empty the server raises a channel
    # exception.
    #
    # * :nowait => true | false (default true)
    # If set, the server will not respond to the method. The client should
    # not wait for a reply method.  If the server could not complete the
    # method it will raise a channel or connection exception.
    #
    def delete opts = {}
      @mq.callback{
        @mq.send Protocol::Queue::Delete.new({ :queue => name,
                                               :nowait => true }.merge(opts))
      }
      @mq.queues.delete @name
      nil
    end

    # This method provides a direct access to the messages in a queue
    # using a synchronous dialogue that is designed for specific types of
    # application where synchronous functionality is more important than
    # performance.
    #
    # The provided block is passed a single message each time pop is called.
    #
    #  EM.run do
    #    exchange = MQ.direct("foo queue")
    #    EM.add_periodic_timer(1) do
    #      exchange.publish("random number #{rand(1000)}")
    #    end
    #    
    #    # note that #bind is never called; it is implicit because
    #    # the exchange and queue names match
    #    queue = MQ.queue('foo queue')
    #    queue.pop { |body| puts "received payload [#{body}]" }
    #
    #    EM.add_periodic_timer(1) { queue.pop }
    #  end
    #
    # If the block takes 2 parameters, both the +header+ and the +body+ will
    # be passed in for processing. The header object is defined by
    # AMQP::Protocol::Header.
    #
    #  EM.run do
    #    exchange = MQ.direct("foo queue")
    #    EM.add_periodic_timer(1) do
    #      exchange.publish("random number #{rand(1000)}")
    #    end
    #    
    #    queue = MQ.queue('foo queue')
    #    queue.pop do |header, body| 
    #      p header
    #      puts "received payload [#{body}]"
    #    end
    #
    #    EM.add_periodic_timer(1) { queue.pop }
    #  end
    #
    # == Options
    # * :no_ack => true | false (default true)
    # If this field is set the server does not expect acknowledgments
    # for messages.  That is, when a message is delivered to the client
    # the server automatically and silently acknowledges it on behalf
    # of the client.  This functionality increases performance but at
    # the cost of reliability.  Messages can get lost if a client dies
    # before it can deliver them to the application.
    #
    # * :nowait => true | false (default true)
    # If set, the server will not respond to the method. The client should
    # not wait for a reply method.  If the server could not complete the
    # method it will raise a channel or connection exception.
    #
    def pop opts = {}, &blk
      @ack = opts[:no_ack] === false

      @on_pop = blk if blk

      @mq.callback{
        @mq.send Protocol::Basic::Get.new({ :queue => name,
                                            :consumer_tag => name,
                                            :no_ack => true,
                                            :nowait => true }.merge(opts))
        @mq.get_queue{ |q|
          q.push(self)
        }
      }

      self
    end

    # Subscribes to asynchronous message delivery.
    #
    # The provided block is passed a single message each time the
    # exchange matches a message to this queue.
    #
    #  EM.run do
    #    exchange = MQ.direct("foo queue")
    #    EM.add_periodic_timer(1) do
    #      exchange.publish("random number #{rand(1000)}")
    #    end
    #    
    #    queue = MQ.queue('foo queue')
    #    queue.subscribe { |body| puts "received payload [#{body}]" }
    #  end
    #
    # If the block takes 2 parameters, both the +header+ and the +body+ will
    # be passed in for processing. The header object is defined by
    # AMQP::Protocol::Header.
    #
    #  EM.run do
    #    exchange = MQ.direct("foo queue")
    #    EM.add_periodic_timer(1) do
    #      exchange.publish("random number #{rand(1000)}")
    #    end
    #    
    #    # note that #bind is never called; it is implicit because
    #    # the exchange and queue names match
    #    queue = MQ.queue('foo queue')
    #    queue.subscribe do |header, body| 
    #      p header
    #      puts "received payload [#{body}]"
    #    end
    #  end
    #
    # == Options
    # * :no_ack => true | false (default true)
    # If this field is set the server does not expect acknowledgments
    # for messages.  That is, when a message is delivered to the client
    # the server automatically and silently acknowledges it on behalf
    # of the client.  This functionality increases performance but at
    # the cost of reliability.  Messages can get lost if a client dies
    # before it can deliver them to the application.
    #
    # * :nowait => true | false (default true)
    # If set, the server will not respond to the method. The client should
    # not wait for a reply method.  If the server could not complete the
    # method it will raise a channel or connection exception.
    #
    def subscribe opts = {}, &blk
      @consumer_tag = "#{name}-#{Kernel.rand(999_999_999_999)}"
      @mq.consumers[@consumer_tag] = self

      raise Error, 'already subscribed to the queue' if @on_msg

      @on_msg = blk
      @ack = opts[:no_ack] === false

      @mq.callback{
        @mq.send Protocol::Basic::Consume.new({ :queue => name,
                                                :consumer_tag => @consumer_tag,
                                                :no_ack => true,
                                                :nowait => true }.merge(opts))
      }
      self
    end

    def unsubscribe opts = {}, &blk
      @on_msg = nil
      @on_cancel = blk
      @mq.callback{
        @mq.send Protocol::Basic::Cancel.new({ :consumer_tag => @consumer_tag }.merge(opts))
      }
      self
    end

    def publish data, opts = {}
      exchange.publish(data, opts)
    end

    # Passes the message to the block passed to pop or subscribe. 
    #
    # Performs an arity check on the block's parameters. If arity == 1, 
    # pass only the message body. If arity != 1, pass the headers and
    # the body to the block.
    #
    # See AMQP::Protocol::Header for the hash properties available from
    # the headers parameter. See #pop or #subscribe for a code example.
    #
    def receive headers, body
      if AMQP.closing
        #You don't need this if your using ack, and if you aren't it doesn't do much good either
        #@mq.callback{
        #  @mq.send Protocol::Basic::Reject.new({
        #    :delivery_tag => headers.properties[:delivery_tag],
        #    :requeue => true
        #  })
        #}
        return
      end

      if cb = (@on_msg || @on_pop)
        cb.call *(cb.arity == 1 ? [body] : [headers, body])
      end

      if @ack && headers && !AMQP.closing
        @mq.callback{
          @mq.send Protocol::Basic::Ack.new({ :delivery_tag => headers.properties[:delivery_tag] })
        }
      end
    end

    def status opts = {}, &blk
      @on_status = blk
      @mq.callback{
        @mq.send Protocol::Queue::Declare.new({ :queue => name,
                                                :passive => true }.merge(opts))
      }
      self
    end

    def recieve_status declare_ok
      if @on_status
        m, c = declare_ok.message_count, declare_ok.consumer_count
        @on_status.call *(@on_status.arity == 1 ? [m] : [m, c])
        @on_status = nil
      end
    end

    def cancelled
      @on_cancel.call if @on_cancel
      @on_cancel = @on_msg = nil
      @mq.consumers.delete @consumer_tag
      @consumer_tag = nil
    end
  
    private
    
    def exchange
      @exchange ||= Exchange.new(@mq, :direct, '', :key => name)
    end
  end
end