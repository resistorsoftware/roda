require "rack"
require "thread"
require "roda/version"

# The main class for Roda.  Roda is built completely out of plugins, with the
# default plugin being Roda::RodaPlugins::Base, so this class is mostly empty
# except for some constants.
class Roda
  # Error class raised by Roda
  class RodaError < StandardError; end

  if defined?(RUBY_ENGINE) && RUBY_ENGINE != 'ruby'
  # :nocov:
    # A thread safe cache class, offering only #[] and #[]= methods,
    # each protected by a mutex.  Used on non-MRI where Hash is not
    # thread safe.
    class RodaCache
      # Create a new thread safe cache.
      def initialize
        @mutex = Mutex.new
        @hash = {}
      end

      # Make getting value from underlying hash thread safe.
      def [](key)
        @mutex.synchronize{@hash[key]}
      end

      # Make setting value in underlying hash thread safe.
      def []=(key, value)
        @mutex.synchronize{@hash[key] = value}
      end
    end
  # :nocov:
  else
    # Hashes are already thread-safe in MRI, due to the GVL, so they
    # can safely be used as a cache.
    RodaCache = Hash
  end

  # Base class used for Roda requests.  The instance methods for this
  # class are added by Roda::RodaPlugins::Base::RequestMethods, the
  # class methods are added by Roda::RodaPlugins::Base::RequestClassMethods.
  class RodaRequest < ::Rack::Request;
    @roda_class = ::Roda
    @match_pattern_cache = ::Roda::RodaCache.new
  end

  # Base class used for Roda responses.  The instance methods for this
  # class are added by Roda::RodaPlugins::Base::ResponseMethods, the class
  # methods are added by Roda::RodaPlugins::Base::ResponseClassMethods.
  class RodaResponse < ::Rack::Response;
    @roda_class = ::Roda
  end

  @app = nil
  @inherit_middleware = true
  @middleware = []
  @opts = {}
  @route_block = nil

  # Module in which all Roda plugins should be stored. Also contains logic for
  # registering and loading plugins.
  module RodaPlugins
    # Stores registered plugins
    @plugins = RodaCache.new

    # If the registered plugin already exists, use it.  Otherwise,
    # require it and return it.  This raises a LoadError if such a
    # plugin doesn't exist, or a RodaError if it exists but it does
    # not register itself correctly.
    def self.load_plugin(name)
      h = @plugins
      unless plugin = h[name]
        require "roda/plugins/#{name}"
        raise RodaError, "Plugin #{name} did not register itself correctly in Roda::RodaPlugins" unless plugin = h[name]
      end
      plugin
    end

    # Register the given plugin with Roda, so that it can be loaded using #plugin
    # with a symbol.  Should be used by plugin files. Example:
    #
    #   Roda::RodaPlugins.register_plugin(:plugin_name, PluginModule)
    def self.register_plugin(name, mod)
      @plugins[name] = mod
    end

    # The base plugin for Roda, implementing all default functionality.
    # Methods are put into a plugin so future plugins can easily override
    # them and call super to get the default behavior.
    module Base
      # Class methods for the Roda class.
      module ClassMethods
        # The rack application that this class uses.
        attr_reader :app

        # Whether middleware from the current class should be inherited by subclasses.
        # True by default, should be set to false when using a design where the parent
        # class accepts requests and uses run to dispatch the request to a subclass.
        attr_accessor :inherit_middleware

        # The settings/options hash for the current class.
        attr_reader :opts

        # The route block that this class uses.
        attr_reader :route_block

        # Call the internal rack application with the given environment.
        # This allows the class itself to be used as a rack application.
        # However, for performance, it's better to use #app to get direct
        # access to the underlying rack app.
        def call(env)
          app.call(env)
        end

        # Clear the middleware stack
        def clear_middleware!
          @middleware.clear
          build_rack_app
        end

        # Create a match_#{key} method in the request class using the given
        # block, so that using a hash key in a request match method will
        # call the block.  The block should return nil or false to not
        # match, and anything else to match.
        #
        #   class App < Roda
        #     hash_matcher(:foo) do |v|
        #       self['foo'] == v
        #     end
        #
        #     route do
        #       r.on :foo=>'bar' do
        #         # matches when param foo has value bar
        #       end
        #     end
        #   end
        def hash_matcher(key, &block)
          request_module{define_method(:"match_#{key}", &block)}
        end

        # When inheriting Roda, copy the shared data into the subclass,
        # and setup the request and response subclasses.
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@inherit_middleware, @inherit_middleware)
          subclass.instance_variable_set(:@middleware, @inherit_middleware ? @middleware.dup : [])
          subclass.instance_variable_set(:@opts, opts.dup)
          subclass.opts.to_a.each do |k,v|
            if (v.is_a?(Array) || v.is_a?(Hash)) && !v.frozen?
              subclass.opts[k] = v.dup
            end
          end
          subclass.instance_variable_set(:@route_block, @route_block)
          subclass.send(:build_rack_app)
          
          request_class = Class.new(self::RodaRequest)
          request_class.roda_class = subclass
          request_class.match_pattern_cache = thread_safe_cache
          subclass.const_set(:RodaRequest, request_class)

          response_class = Class.new(self::RodaResponse)
          response_class.roda_class = subclass
          subclass.const_set(:RodaResponse, response_class)
        end

        # Load a new plugin into the current class.  A plugin can be a module
        # which is used directly, or a symbol represented a registered plugin
        # which will be required and then used.
        #
        #   Roda.plugin PluginModule
        #   Roda.plugin :csrf
        def plugin(plugin, *args, &block)
          if plugin.is_a?(Symbol)
            plugin = RodaPlugins.load_plugin(plugin)
          end

          if plugin.respond_to?(:load_dependencies)
            plugin.load_dependencies(self, *args, &block)
          end

          if defined?(plugin::InstanceMethods)
            include(plugin::InstanceMethods)
          end
          if defined?(plugin::ClassMethods)
            extend(plugin::ClassMethods)
          end
          if defined?(plugin::RequestMethods)
            self::RodaRequest.send(:include, plugin::RequestMethods)
          end
          if defined?(plugin::RequestClassMethods)
            self::RodaRequest.extend(plugin::RequestClassMethods)
          end
          if defined?(plugin::ResponseMethods)
            self::RodaResponse.send(:include, plugin::ResponseMethods)
          end
          if defined?(plugin::ResponseClassMethods)
            self::RodaResponse.extend(plugin::ResponseClassMethods)
          end
          
          if plugin.respond_to?(:configure)
            plugin.configure(self, *args, &block)
          end
        end

        # Include the given module in the request class. If a block
        # is provided instead of a module, create a module using the
        # the block. Example:
        #
        #   Roda.request_module SomeModule
        #
        #   Roda.request_module do
        #     def description
        #       "#{request_method} #{path_info}"
        #     end
        #   end
        #
        #   Roda.route do |r|
        #     r.description
        #   end
        def request_module(mod = nil, &block)
          module_include(:request, mod, &block)
        end
    
        # Include the given module in the response class. If a block
        # is provided instead of a module, create a module using the
        # the block. Example:
        #
        #   Roda.response_module SomeModule
        #
        #   Roda.response_module do
        #     def error!
        #       self.status = 500
        #     end
        #   end
        #
        #   Roda.route do |r|
        #     response.error!
        #   end
        def response_module(mod = nil, &block)
          module_include(:response, mod, &block)
        end

        # Setup routing tree for the current Roda application, and build the
        # underlying rack application using the stored middleware. Requires
        # a block, which is yielded the request.  By convention, the block
        # argument should be named +r+.  Example:
        #
        #   Roda.route do |r|
        #     r.root do
        #       "Root"
        #     end
        #   end
        #
        # This should only be called once per class, and if called multiple
        # times will overwrite the previous routing.
        def route(&block)
          @route_block = block
          build_rack_app
        end

        # A new thread safe cache instance.  This is a method so it can be
        # easily overridden for alternative implementations.
        def thread_safe_cache
          RodaCache.new
        end

        # Add a middleware to use for the rack application.  Must be
        # called before calling #route to have an effect. Example:
        #
        #   Roda.use Rack::Session::Cookie, :secret=>ENV['secret']
        def use(*args, &block)
          @middleware << [args, block]
          build_rack_app
        end

        private

        # Build the rack app to use
        def build_rack_app
          if block = @route_block
            builder = Rack::Builder.new
            @middleware.each{|a, b| builder.use(*a, &b)}
            builder.run lambda{|env| allocate.call(env, &block)}
            @app = builder.to_app
          end
        end

        # Backbone of the request_module and response_module support.
        def module_include(type, mod)
          if type == :response
            klass = self::RodaResponse
            iv = :@response_module
          else
            klass = self::RodaRequest
            iv = :@request_module
          end

          if mod
            raise RodaError, "can't provide both argument and block to response_module" if block_given?
            klass.send(:include, mod)
          else
            if instance_variable_defined?(iv)
              mod = instance_variable_get(iv)
            else
              mod = instance_variable_set(iv, Module.new)
              klass.send(:include, mod)
            end

            mod.module_eval(&Proc.new) if block_given?
          end

          mod
        end
      end

      # Instance methods for the Roda class.
      module InstanceMethods
        # Create a request and response of the appopriate
        # class, the instance_exec the route block with
        # the request, handling any halts.  This is not usually
        # called directly.
        def call(env, &block)
          @_request = self.class::RodaRequest.new(self, env)
          @_response = self.class::RodaResponse.new
          _route(&block)
        end

        # The environment hash for the current request. Example:
        #
        #   env['REQUEST_METHOD'] # => 'GET'
        def env
          @_request.env
        end

        # The class-level options hash.  This should probably not be
        # modified at the instance level. Example:
        #
        #   Roda.plugin :render
        #   Roda.route do |r|
        #     opts[:render_opts].inspect
        #   end
        def opts
          self.class.opts
        end

        # The instance of the request class related to this request.
        # This is the same object yielded by Roda.route.
        def request
          @_request
        end

        # The instance of the response class related to this request.
        def response
          @_response
        end

        # The session hash for the current request. Raises RodaError
        # if no session existsExample:
        #
        #   session # => {}
        def session
          @_request.session
        end

        private

        # Internals of #call, extracted so that plugins can override
        # behavior after the request and response have been setup.
        def _route(&block)
          catch(:halt) do
            r = @_request
            r.block_result(instance_exec(r, &block))
            @_response.finish
          end
        end
      end

      # Class methods for RodaRequest
      module RequestClassMethods
        # Reference to the Roda class related to this request class.
        attr_accessor :roda_class

        # The cache to use for match patterns for this request class.
        attr_accessor :match_pattern_cache

        # Return the cached pattern for the given object.  If the object is
        # not already cached, yield to get the basic pattern, and convert the
        # basic pattern to a pattern that does not partial segments.
        def cached_matcher(obj)
          cache = @match_pattern_cache

          unless pattern = cache[obj]
            pattern = cache[obj] = consume_pattern(yield)
          end

          pattern
        end

        # Since RodaRequest is anonymously subclassed when Roda is subclassed,
        # and then assigned to a constant of the Roda subclass, make inspect
        # reflect the likely name for the class.
        def inspect
          "#{roda_class.inspect}::RodaRequest"
        end

        private

        # The pattern to use for consuming, based on the given argument.  The returned
        # pattern requires the path starts with a string and does not match partial
        # segments.
        def consume_pattern(pattern)
          /\A\/(?:#{pattern})(?=\/|\z)/
        end
      end

      # Instance methods for RodaRequest, mostly related to handling routing
      # for the request.
      module RequestMethods
        PATH_INFO = "PATH_INFO".freeze
        SCRIPT_NAME = "SCRIPT_NAME".freeze
        REQUEST_METHOD = "REQUEST_METHOD".freeze
        EMPTY_STRING = "".freeze
        SLASH = "/".freeze
        SEGMENT = "([^\\/]+)".freeze
        TERM_INSPECT = "TERM".freeze
        GET_REQUEST_METHOD = 'GET'.freeze
        SESSION_KEY = 'rack.session'.freeze

        TERM = Object.new
        def TERM.inspect
          TERM_INSPECT
        end
        TERM.freeze

        # The current captures for the request.  This gets modified as routing
        # occurs.
        attr_reader :captures

        # The Roda instance related to this request object.  Useful if routing
        # methods need access to the scope of the Roda route block.
        attr_reader :scope

        # Store the roda instance and environment.
        def initialize(scope, env)
          @scope = scope
          @captures = []
          super(env)
        end

        # Handle match block return values.  By default, if a string is given
        # and the response is empty, use the string as the response body.
        def block_result(result)
          res = response
          if res.empty? && (body = block_result_body(result))
            res.write(body)
          end
        end

        # Match GET requests.  If no arguments are provided, matches all GET
        # requests, otherwise, matches only GET requests where the arguments
        # given fully consume the path.
        def get(*args, &block)
          _verb(args, &block) if is_get?
        end

        # Immediately stop execution of the route block and return the given
        # rack response array of status, headers, and body.  If no argument
        # is given, uses the current response.
        #
        #   r.halt [200, {'Content-Type'=>'text/html'}, ['Hello World!']]
        #   
        #   response.status = 200
        #   response['Content-Type'] = 'text/html'
        #   response.write 'Hello World!'
        #   r.halt
        def halt(res=response.finish)
          throw :halt, res
        end

        # Show information about current request, including request class,
        # request method and full path.
        #
        #   r.inspect
        #   # => '#<Roda::RodaRequest GET /foo/bar>'
        def inspect
          "#<#{self.class.inspect} #{@env[REQUEST_METHOD]} #{path}>"
        end

        # Does a terminal match on the current path, matching only if the arguments
        # have fully matched the path.  If it matches, the match block is
        # executed, and when the match block returns, the rack response is
        # returned.
        # 
        #   r.path_info
        #   # => "/foo/bar"
        #
        #   r.is 'foo' do
        #     # does not match, as path isn't fully matched (/bar remaining)
        #   end
        #
        #   r.is 'foo/bar' do
        #     # matches as path is empty after matching
        #   end
        #
        # If no arguments are given, matches if the path is already fully matched.
        # 
        #   r.on 'foo/bar' do
        #     r.is do
        #       # matches as path is already empty
        #     end
        #   end
        #
        # Note that this matches only if the path after matching the arguments
        # is empty, not if it still contains a trailing slash:
        #
        #   r.path_info
        #   # =>  "/foo/bar/"
        #
        #   r.is 'foo/bar' do
        #     # does not match, as path isn't fully matched (/ remaining)
        #   end
        # 
        #   r.is 'foo/bar/' do
        #     # matches as path is empty after matching
        #   end
        # 
        #   r.on 'foo/bar' do
        #     r.is "" do
        #       # matches as path is empty after matching
        #     end
        #   end
        def is(*args, &block)
          if args.empty?
            if empty_path?
              always(&block)
            end
          else
            args << TERM
            if_match(args, &block)
          end
        end

        # Optimized method for whether this request is a +GET+ request.
        # Similar to the default Rack::Request get? method, but can be
        # overridden without changing rack's behavior.
        def is_get?
          @env[REQUEST_METHOD] == GET_REQUEST_METHOD
        end

        # Does a match on the path, matching only if the arguments
        # have matched the path.  Because this doesn't fully match the
        # path, this is usually used to setup branches of the routing tree,
        # not for final handling of the request.
        # 
        #   r.path_info
        #   # => "/foo/bar"
        #
        #   r.on 'foo' do
        #     # matches, path is /bar after matching
        #   end
        #
        #   r.on 'bar' do
        #     # does not match
        #   end
        #
        # Like other routing methods, If it matches, the match block is
        # executed, and when the match block returns, the rack response is
        # returned.  However, in general you will call another routing method
        # inside the match block that fully matches the path and does the
        # final handling for the request:
        #
        #   r.on 'foo' do
        #     r.is 'bar' do
        #       # handle /foo/bar request
        #     end
        #   end
        def on(*args, &block)
          if args.empty?
            always(&block)
          else
            if_match(args, &block)
          end
        end

        # This an an optimized version of Rack::Request#path.
        #
        #   r.env['SCRIPT_NAME'] = '/foo'
        #   r.env['PATH_INFO'] = '/bar'
        #   r.path
        #   # => '/foo/bar'
        def path
          e = @env
          "#{e[SCRIPT_NAME]}#{e[PATH_INFO]}"
        end
        alias full_path_info path

        # Match POST requests.  If no arguments are provided, matches all POST
        # requests, otherwise, matches only POST requests where the arguments
        # given fully consume the path.
        def post(*args, &block)
          _verb(args, &block) if post?
        end

        # Immediately redirect to the path using the status code.  This ends
        # the processing of the request:
        #
        #   r.redirect '/page1', 301 if r['param'] == 'value1'
        #   r.redirect '/page2' # uses 302 status code
        #   response.status = 404 # not reached
        #   
        # If you do not provide a path, by default it will redirect to the same
        # path if the request is not a +GET+ request.  This is designed to make
        # it easy to use where a +POST+ request to a URL changes state, +GET+
        # returns the current state, and you want to show the current state
        # after changing:
        #
        #   r.is "foo" do
        #     r.get do
        #       # show state
        #     end
        #   
        #     r.post do
        #       # change state
        #       r.redirect
        #     end
        #   end
        def redirect(path=default_redirect_path, status=default_redirect_status)
          response.redirect(path, status)
          throw :halt, response.finish
        end

        # The response related to the current request.  See ResponseMethods for
        # instance methods for the response, but in general the most common usage
        # is to override the response status and headers:
        #
        #   response.status = 200
        #   response['Header-Name'] = 'Header value'
        def response
          scope.response
        end

        # Return the Roda class related to this request.
        def roda_class
          self.class.roda_class
        end

        # Routing matches that only matches +GET+ requests where the current
        # path is +/+.  If it matches, the match block is executed, and when
        # the match block returns, the rack response is returned.
        #
        #   [r.request_method, r.path_info]
        #   # => ['GET', '/']
        #
        #   r.root do
        #     # matches
        #   end
        #
        # This is usuable inside other match blocks:
        #
        #   [r.request_method, r.path_info]
        #   # => ['GET', '/foo/']
        #
        #   r.on 'foo' do
        #     r.root do
        #       # matches
        #     end
        #   end
        #
        # Note that this does not match non-+GET+ requests:
        #
        #   [r.request_method, r.path_info]
        #   # => ['POST', '/']
        #
        #   r.root do
        #     # does not match
        #   end
        #
        # Use <tt>r.post ""</tt> for +POST+ requests where the current path
        # is +/+.
        # 
        # Nor does it match empty paths:
        #
        #   [r.request_method, r.path_info]
        #   # => ['GET', '/foo']
        #
        #   r.on 'foo' do
        #     r.root do
        #       # does not match
        #     end
        #   end
        #
        # Use <tt>r.get true</tt> to handle +GET+ requests where the current
        # path is empty.
        def root(&block)
          if path_to_match == SLASH && is_get?
            always(&block)
          end
        end

        # Call the given rack app with the environment and return the response
        # from the rack app as the response for this request.  This ends
        # the processing of the request:
        #
        #   r.run(proc{[403, {}, []]}) unless r['letmein'] == '1'
        #   r.run(proc{[404, {}, []]})
        #   response.status = 404 # not reached
        def run(app)
          throw :halt, app.call(@env)
        end

        # The session for the current request.  Raises a RodaError if
        # a session handler has not been loaded.
        def session
          @env[SESSION_KEY] || raise(RodaError, "You're missing a session handler. You can get started by adding use Rack::Session::Cookie")
        end

        private

        # Match any of the elements in the given array.  Return at the
        # first match without evaluating future matches.  Returns false
        # if no elements in the array match.
        def _match_array(matcher)
          matcher.any? do |m|
            if matched = match(m)
              if m.is_a?(String)
                @captures.push(m)
              end
            end

            matched
          end
        end

        # Match the given hash if all hash matchers match.
        def _match_hash(hash)
          hash.all?{|k,v| send("match_#{k}", v)}
        end

        # Match the given regexp exactly if it matches a full segment.
        def _match_regexp(re)
          consume(self.class.cached_matcher(re){re})
        end

        # Match the given string to the request path.  Regexp escapes the
        # string so that regexp metacharacters are not matched, and recognizes
        # colon tokens for placeholders.
        def _match_string(str)
          consume(self.class.cached_matcher(str){Regexp.escape(str).gsub(/:(\w+)/){|m| _match_symbol_regexp($1)}})
        end

        # Match the given symbol if any segment matches.
        def _match_symbol(sym)
          consume(self.class.cached_matcher(sym){_match_symbol_regexp(sym)})
        end

        # The regular expression to use for matching symbols.  By default, any non-empty
        # segment matches.
        def _match_symbol_regexp(s)
          SEGMENT
        end

        # Backbone of the verb method support, using a terminal match if
        # args is not empty, or a regular match if it is empty.
        def _verb(args, &block)
          if args.empty?
            always(&block)
          else
            args << TERM
            if_match(args, &block)
          end
        end

        # Yield to the match block and return rack response after the block returns.
        def always
          block_result(yield)
          throw :halt, response.finish
        end

        # The body to use for the response if the response does not return
        # a body.  By default, a String is returned directly, and nil is
        # returned otherwise.
        def block_result_body(result)
          if result.is_a?(String)
            result
          end
        end

        # Attempts to match the pattern to the current path.  If there is no
        # match, returns false without changes.  Otherwise, modifies
        # SCRIPT_NAME to include the matched path, removes the matched
        # path from PATH_INFO, and updates captures with any regex captures.
        def consume(pattern)
          if matchdata = path_to_match.match(pattern)
            update_path_to_match(matchdata.post_match)
            @captures.concat(matchdata.captures)
          end
        end

        # The default path to use for redirects when a path is not given.
        # For non-GET requests, redirects to the current path, which will
        # trigger a GET request.  This is to make the common case where
        # a POST request will redirect to a GET request at the same location
        # will work fine.
        #
        # If the current request is a GET request, raise an error, as otherwise
        # it is easy to create an infinite redirect.
        def default_redirect_path
          raise RodaError, "must provide path argument to redirect for get requests" if is_get?
          path
        end

        # The default status to use for redirects if a status is not provided,
        # 302 by default.
        def default_redirect_status
          302
        end

        # Whether the current path is considered empty.
        def empty_path?
          path_to_match == EMPTY_STRING
        end

        # If all of the arguments match, yields to the match block and
        # returns the rack response when the block returns.  If any of
        # the match arguments doesn't match, does nothing.
        def if_match(args)
          keep_path_to_match do
            # For every block, we make sure to reset captures so that
            # nesting matchers won't mess with each other's captures.
            @captures.clear

            return unless match_all(args)
            block_result(yield(*captures))
            throw :halt, response.finish
          end
        end
        
        # Yield to the block, restoring SCRIPT_NAME and PATH_INFO to
        # their initial values before returning from the block.
        def keep_path_to_match
          env = @env
          script = env[sn = SCRIPT_NAME]
          path = env[pi = PATH_INFO]
          yield
        ensure
          env[sn] = script
          env[pi] = path
        end

        # Attempt to match the argument to the given request, handling
        # common ruby types.
        def match(matcher)
          case matcher
          when String
            _match_string(matcher)
          when Regexp
            _match_regexp(matcher)
          when Symbol
            _match_symbol(matcher)
          when TERM
            empty_path?
          when Hash
            _match_hash(matcher)
          when Array
            _match_array(matcher)
          when Proc
            matcher.call
          else
            matcher
          end
        end

        # Match only if all of the arguments in the given array match.
        def match_all(args)
          args.all?{|arg| match(arg)}
        end

        # Match files with the given extension.  Requires that the
        # request path end with the extension.
        def match_extension(ext)
          consume(self.class.cached_matcher([:extension, ext]){/([^\\\/]+)\.#{ext}/})
        end

        # Match by request method.  This can be an array if you want
        # to match on multiple methods.
        def match_method(type)
          if type.is_a?(Array)
            type.any?{|t| match_method(t)}
          else
            type.to_s.upcase == @env[REQUEST_METHOD]
          end
        end

        # Match the given parameter if present, even if the parameter is empty.
        # Adds any match to the captures.
        def match_param(key)
          if v = self[key]
            @captures << v
          end
        end

        # Match the given parameter if present and not empty.
        # Adds any match to the captures.
        def match_param!(key)
          if (v = self[key]) && !v.empty?
            @captures << v
          end
        end

        # The current path to match requests against.  This is the same as PATH_INFO
        # in the environment, which gets updated as the request is being routed.
        def path_to_match
          @env[PATH_INFO]
        end

        # Update PATH_INFO and SCRIPT_NAME based on the matchend and remaining variables.
        def update_path_to_match(remaining)
          e = @env

          # Don't mutate SCRIPT_NAME, breaks try
          e[SCRIPT_NAME] += e[pi = PATH_INFO].chomp(remaining)
          e[pi] = remaining
        end
      end

      # Class methods for RodaResponse
      module ResponseClassMethods
        # Reference to the Roda class related to this response class.
        attr_accessor :roda_class

        # Since RodaResponse is anonymously subclassed when Roda is subclassed,
        # and then assigned to a constant of the Roda subclass, make inspect
        # reflect the likely name for the class.
        def inspect
          "#{roda_class.inspect}::RodaResponse"
        end
      end

      # Instance methods for RodaResponse
      module ResponseMethods
        CONTENT_LENGTH = "Content-Length".freeze
        DEFAULT_HEADERS = {"Content-Type" => "text/html".freeze}.freeze
        LOCATION = "Location".freeze

        # The hash of response headers for the current response.
        attr_reader :headers

        # The status code to use for the response.  If none is given, will use 200
        # code for non-empty responses and a 404 code for empty responses.
        attr_accessor :status

        # Set the default headers when creating a response.
        def initialize
          @status  = nil
          @headers = {}
          @body    = []
          @length  = 0
        end

        # Return the response header with the given key. Example:
        #
        #   response['Content-Type'] # => 'text/html'
        def [](key)
          @headers[key]
        end

        # Set the response header with the given key to the given value.
        #
        #   response['Content-Type'] = 'application/json'
        def []=(key, value)
          @headers[key] = value
        end

        # The default headers to use for responses.
        def default_headers
          DEFAULT_HEADERS
        end

        # Modify the headers to include a Set-Cookie value that
        # deletes the cookie.  A value hash can be provided to
        # override the default one used to delete the cookie.
        # Example:
        #
        #   response.delete_cookie('foo')
        #   response.delete_cookie('foo', :domain=>'example.org')
        def delete_cookie(key, value = {})
          ::Rack::Utils.delete_cookie_header!(@headers, key, value)
        end

        # Whether the response body has been written to yet.  Note
        # that writing an empty string to the response body marks
        # the response as not empty. Example:
        #
        #   response.empty? # => true
        #   response.write('a')
        #   response.empty? # => false
        def empty?
          @body.empty?
        end

        # Return the rack response array of status, headers, and body
        # for the current response.  If the status has not been set,
        # uses a 200 status if the body has been written to, otherwise
        # uses a 404 status.  Adds the Content-Length header to the
        # size of the response body.
        #
        # Example:
        #
        #   response.finish
        #   #  => [200,
        #   #      {'Content-Type'=>'text/html', 'Content-Length'=>'0'},
        #   #      []]
        def finish
          b = @body
          s = (@status ||= b.empty? ? 404 : 200)
          set_default_headers
          h = @headers
          h[CONTENT_LENGTH] ||= @length.to_s
          [s, h, b]
        end

        # Return the rack response array using a given body.  Assumes a
        # 200 response status unless status has been explicitly set,
        # and doesn't add the Content-Length header or use the existing
        # body.
        def finish_with_body(body)
          set_default_headers
          [@status || 200, @headers, body]
        end

        # Show response class, status code, response headers, and response body
        def inspect
          "#<#{self.class.inspect} #{@status.inspect} #{@headers.inspect} #{@body.inspect}>"
        end

        # Set the Location header to the given path, and the status
        # to the given status.  Example:
        #
        #   response.redirect('foo', 301)
        #   response.redirect('bar')
        def redirect(path, status = 302)
          @headers[LOCATION] = path
          @status  = status
        end

        # Return the Roda class related to this response.
        def roda_class
          self.class.roda_class
        end

        # Set the cookie with the given key in the headers.
        #
        #   response.set_cookie('foo', 'bar')
        #   response.set_cookie('foo', :value=>'bar', :domain=>'example.org')
        def set_cookie(key, value)
          ::Rack::Utils.set_cookie_header!(@headers, key, value)
        end

        # Write to the response body.  Returns nil.
        #
        #   response.write('foo')
        def write(str)
          s = str.to_s
          @length += s.bytesize
          @body << s
          nil
        end

        private

        # For each default header, if a header has not already been set for the
        # response, set the header in the response.
        def set_default_headers
          h = @headers
          default_headers.each do |k,v|
            h[k] ||= v
          end
        end
      end
    end
  end

  extend RodaPlugins::Base::ClassMethods
  plugin RodaPlugins::Base
end
