# frozen_string_literal: true

module OroGen
    module Gen
        module RTT_CPP
            # Returns the directory where Orogen's lib part sits (i.e. where
            # autobuild.rb and autobuild/ are)
            def self.base_dir
                File.expand_path(File.join("..", ".."), File.dirname(__FILE__))
            end

            # call-seq:
            #   touch path1, path2, ..., file_name
            #
            # Creates an empty file path1/path2/.../file_name
            def self.touch(*args)
                path = File.expand_path(File.join(*args))
                FileUtils.touch path
                generated_files << path
            end

            # Returns the C++ code which changes the current namespace from +old+
            # to +new+. +indent_size+ is the count of indent spaces between
            # namespaces.
            def self.adapt_namespace(old, new, indent_size = 4)
                old = old.split("/").delete_if(&:empty?)
                new = new.split("/").delete_if(&:empty?)
                indent = old.size * indent_size

                result = "".dup

                while !old.empty? && old.first == new.first
                    old.shift
                    new.shift
                end
                until old.empty?
                    indent -= indent_size
                    result << " " * indent + "}\n"
                    old.shift
                end
                until new.empty?
                    result << "#{" " * indent}namespace #{new.first} {\n"
                    indent += indent_size
                    new.shift
                end

                result
            end

            class BuildDependency
                attr_reader :var_name
                attr_reader :pkg_name

                attr_reader :context

                def initialize(var_name, pkg_name)
                    @var_name = var_name.gsub(/[^\w]/, "_")
                    @pkg_name = pkg_name
                    @context = []
                end

                def in_context(*args)
                    context << args.to_set
                    self
                end

                def remove_context(*args)
                    args = args.to_set
                    @context = context.dup
                    context.delete_if do |ctx|
                        (args & ctx).size == args.size
                    end
                    self
                end

                def in_context?(*args)
                    args = args.to_set
                    context.any? do |ctx|
                        (args & ctx).size == args.size
                    end
                end
            end

            def self.cmake_pkgconfig_require(depspec, context = "core")
                cmake_txt = "set(DEPS_CFLAGS_OTHER \"\")\n"
                cmake_txt += depspec.inject([]) do |result, s|
                    result << "orogen_pkg_check_modules(#{s.var_name} REQUIRED #{s.pkg_name})"
                    if s.in_context?(context, "include")
                        result << "include_directories(${#{s.var_name}_INCLUDE_DIRS})"
                        result << "list(APPEND DEPS_CFLAGS_OTHER ${#{s.var_name}_CFLAGS_OTHER})"
                    end
                    if s.in_context?(context, "link")
                        result << "link_directories(${#{s.var_name}_LIBRARY_DIRS})"
                    end
                    result
                end.join("\n") + "\n"
                cmake_txt += "list(REMOVE_DUPLICATES DEPS_CFLAGS_OTHER)\n"
                cmake_txt += "add_definitions(${DEPS_CFLAGS_OTHER})\n"
                cmake_txt
            end

            def self.each_pkgconfig_link_dependency(context, depspec)
                return enum_for(__method__, context, depspec) unless block_given?

                depspec.each do |s|
                    yield "${#{s.var_name}_LIBRARIES}" if s.in_context?(context, "link")
                end
            end

            def self.cmake_pkgconfig_link(context, target, depspec)
                each_pkgconfig_link_dependency(context, depspec).map do |dep|
                    "target_link_libraries(#{target} #{dep})"
                end.join("\n") + "\n"
            end

            def self.cmake_pkgconfig_link_corba(target, depspec)
                cmake_pkgconfig_link("corba", target, depspec)
            end

            def self.cmake_pkgconfig_link_noncorba(target, depspec)
                cmake_pkgconfig_link("core", target, depspec)
            end

            class << self
                attr_accessor :job_server
                attr_accessor :parallel_level
            end

            # @api private
            #
            # Job server interface that does nothing (i.e. does not allocate tokens)
            class NullJobServer
                def get
                    yield if block_given?
                end

                def put; end
            end

            @job_server = NullJobServer.new
            @parallel_level = 1

            # An implementation of the make job server "protocol"
            class JobServer
                def self.from_fds(pipe_r, pipe_w)
                    pipe_r = IO.for_fd(pipe_r)
                    pipe_w = IO.for_fd(pipe_w)
                    pipe_w.sync = true
                    new(pipe_r, pipe_w)
                end

                def self.standalone(parallel_level)
                    pipe_r, pipe_w = IO.pipe
                    # The current thread already has a token (this is the
                    # general make job server protocol)
                    pipe_w.write(" " * parallel_level)
                    new(pipe_r, pipe_w)
                end

                def initialize(pipe_r, pipe_w)
                    @pipe_r = pipe_r
                    @pipe_w = pipe_w
                end

                # Wait for a work token to be available and acquired
                def get
                    @pipe_r.read(1)
                    return unless block_given?

                    begin
                        yield
                    ensure
                        put
                    end
                end

                # Put a work token back into the pool
                def put
                    @pipe_w.write(" ")
                end
            end
        end
    end
end
