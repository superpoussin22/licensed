# frozen_string_literal: true
require "English"

module Licensed
  module Source
    class Cabal
      DEPENDENCY_REGEX = /\s*.+?\s*/.freeze
      DEFAULT_TARGETS = %w{executable library}.freeze

      def self.type
        "cabal"
      end

      def initialize(config)
        @config = config
      end

      def enabled?
        cabal_file_dependencies.any? && ghc?
      end

      def dependencies
        @dependencies ||= package_ids.map do |id|
          package = package_info(id)

          path, search_root = package_docs_dirs(package)
          Dependency.new(path, {
            "type"     => Cabal.type,
            "name"     => package["name"],
            "version"  => package["version"],
            "summary"  => package["synopsis"],
            "homepage" => safe_homepage(package["homepage"]),
            "search_root" => search_root
          })
        end
      end

      # Returns the packages document directory and search root directory
      # as an array
      def package_docs_dirs(package)
        unless package["haddock-html"]
          # default to a local vendor directory if haddock-html property
          # isn't available
          return [File.join(@config.pwd, "vendor", package["name"]), nil]
        end

        html_dir = package["haddock-html"]
        data_dir = package["data-dir"]
        return [html_dir, nil] unless data_dir

        # only allow data directories that are ancestors of the html directory
        unless Pathname.new(html_dir).fnmatch?(File.join(data_dir, "**"))
          data_dir = nil
        end

        [html_dir, data_dir]
      end

      # Returns a homepage url that enforces https and removes url fragments
      def safe_homepage(homepage)
        return unless homepage
        # use https and remove url fragment
        homepage.gsub(/http:/, "https:")
                .gsub(/#[^?]*\z/, "")
      end

      # Returns a `Set` of the package ids for all cabal dependencies
      def package_ids
        recursive_dependencies(cabal_file_dependencies)
      end

      # Recursively finds the dependencies for each cabal package.
      # Returns a `Set` containing the package names for all dependencies
      def recursive_dependencies(package_names, results = Set.new)
        return [] if package_names.nil? || package_names.empty?

        new_packages = Set.new(package_names) - results.to_a
        return [] if new_packages.empty?

        results.merge new_packages

        dependencies = new_packages.flat_map { |n| package_dependencies(n) }
                                   .compact

        return results if dependencies.empty?

        results.merge recursive_dependencies(dependencies, results)
      end

      # Returns an array of dependency package names for the cabal package
      # given by `id`
      def package_dependencies(id, full_id = true)
        package_dependencies_command(id, full_id).gsub("depends:", "")
                                                 .split
                                                 .map(&:strip)
      end

      # Returns the output of running `ghc-pkg field depends` for a package id
      # Optionally allows for interpreting the given id as an
      # installed package id (`--ipid`)
      def package_dependencies_command(id, full_id)
        fields = %w(depends)

        if full_id
          ghc_pkg_field_command(id, fields, "--ipid")
        else
          ghc_pkg_field_command(id, fields)
        end
      end

      # Returns package information as a hash for the given id
      def package_info(id)
        package_info_command(id).lines.each_with_object({}) do |line, info|
          key, value = line.split(":", 2).map(&:strip)
          next unless key && value

          info[key] = value
        end
      end

      # Returns the output of running `ghc-pkg field` to obtain package information
      def package_info_command(id)
        fields = %w(name version synopsis homepage haddock-html data-dir)
        ghc_pkg_field_command(id, fields, "--ipid")
      end

      # Runs a `ghc-pkg field` command for a given set of fields and arguments
      # Automatically includes ghc package DB locations in the command
      def ghc_pkg_field_command(id, fields, *args)
        Licensed::Shell.execute("ghc-pkg", "field", id, fields.join(","), *args, *package_db_args, allow_failure: true)
      end

      # Returns an array of ghc package DB locations as specified in the app
      # configuration
      def package_db_args
        return [] unless @config["cabal"]
        Array(@config["cabal"]["ghc_package_db"]).map do |path|
          next "--#{path}" if %w(global user).include?(path)
          path = realized_ghc_package_path(path)
          path = File.expand_path(path, Licensed::Git.repository_root)

          next unless File.exist?(path)
          "--package-db=#{path}"
        end.compact
      end

      # Returns a ghc package path with template markers replaced by live
      # data
      def realized_ghc_package_path(path)
        path.gsub("<ghc_version>", ghc_version)
      end

      # Returns a set containing the top-level dependencies found in cabal files
      def cabal_file_dependencies
        cabal_files.each_with_object(Set.new) do |cabal_file, packages|
          content = File.read(cabal_file)
          next if content.nil? || content.empty?

          # add any dependencies for matched targets from the cabal file.
          # by default this will find executable and library dependencies
          content.scan(cabal_file_regex).each do |match|
            # match[1] is a string of "," separated dependencies
            dependencies = match[1].split(",").map(&:strip)
            dependencies.each do |dep|
              # the dependency might have a version specifier.
              # remove it so we can get the full id specifier for each package
              id = cabal_package_id(dep.split(/\s/)[0])
              packages.add(id) if id
            end
          end
        end
      end

      # Returns an installed package id for the package.
      def cabal_package_id(package_name)
        field = ghc_pkg_field_command(package_name, ["id"])
        id = field.split(":", 2)[1]
        id.strip if id
      end

      # Find `build-depends` lists from specified targets in a cabal file
      def cabal_file_regex
        # this will match 0 or more occurences of
        # match[0] - specifier, e.g. executable, library, etc
        # match[1] - full list of matched dependencies
        # match[2] - first matched dependency (required)
        # match[3] - remainder of matched dependencies (not required)
        @cabal_file_regex ||= /
          # match a specifier, e.g. library or executable
          ^(#{cabal_file_targets.join("|")})
            .*? # stuff

            # match a list of 1 or more dependencies
            build-depends:(#{DEPENDENCY_REGEX}(,#{DEPENDENCY_REGEX})*)\n
        /xmi
      end

      # Returns the targets to search for `build-depends` in a cabal file
      def cabal_file_targets
        targets = Array(@config.dig("cabal", "cabal_file_targets"))
        targets.push(*DEFAULT_TARGETS) if targets.empty?
        targets
      end

      # Returns an array of the local directory cabal package files
      def cabal_files
        @cabal_files ||= Dir.glob(File.join(@config.pwd, "*.cabal"))
      end

      # Returns the ghc cli tool version
      def ghc_version
        return unless ghc?
        @version ||= Licensed::Shell.execute("ghc", "--numeric-version")
      end

      # Returns whether the ghc cli tool is available
      def ghc?
        @ghc ||= Licensed::Shell.tool_available?("ghc")
      end
    end
  end
end
