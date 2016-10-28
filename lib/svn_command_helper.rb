require "svn_command_helper/version"
require 'pathname'
require 'yaml'
require 'time'
require 'tmpdir'
require 'libxml'
require "system_command_helper"

# Subversion command helper
module SvnCommandHelper
  # Subversion native command and some utilities
  module Svn
    # module methods
    class << self
      include ::SystemCommandHelper

      # svn commit
      # @param [String] message commit message
      # @param [path string like] path target path
      def commit(message, path = ".")
        if cap("svn status #{path}").empty?
          sys "svn revert -R #{path}"
          puts "[WARNING] no change: #{message}"
        else
          sys "svn commit -m '#{message}' #{path}"
        end
        sys "svn update #{path}"
      end

      # svn list
      # @param [uri string like] uri target uri
      # @param [Boolean] recursive --recursive
      # @return [Array<ListItem>] paths
      def list(uri, recursive = false)
        if @list_cache && @list_cache[recursive][uri]
          @list_cache[recursive][uri]
        else
          list_str = cap("svn list --xml #{recursive ? '-R' : ''} #{uri}")
          list = LibXML::XML::Document.string(list_str).find("//lists/list/entry").map do |entry|
            commit = entry.find_first("commit")
            ListItem.new(
              kind: entry["kind"],
              path: entry.find_first("name").content,
              revision: commit["revision"].to_i,
              author: commit.find_first("author").content,
              date: Time.iso8601(commit.find_first("date").content)
            )
          end
          @list_cache[recursive][uri] = list if @list_cache
          list
        end
      end

      class ListItem
        attr_reader :kind, :path, :revision, :author, :date
        def initialize(kind:, path:, revision:, author:, date:)
          @kind = kind
          @path = path
          @revision = revision
          @author = author
          @date = date
        end
      end

      # svn list --recursive
      # @param [uri string like] uri target uri
      # @return [Array<String>] paths
      def list_recursive(uri)
        list(uri, true)
      end

      # svn list -> grep only files
      # @param [uri string like] uri target uri
      # @param [Boolean] recursive --recursive
      # @return [Array<String>] file paths
      def list_files(uri, recursive = false)
        list(uri, recursive).select {|entry| entry.kind == "file"}
      end

      # svn list --recursive -> grep only files
      # @param [uri string like] uri target uri
      # @return [Array<String>] file paths
      def list_files_recursive(uri)
        list_files(uri, true)
      end

      # svn list cache block
      def list_cache(&block)
        @list_cache = {true => {}, false => {}}
        block.call
        @list_cache = nil
      end

      # check svn uri exists or not
      # @param [uri string like] uri target uri
      # @return [Boolean] true if exists
      def exist?(uri)
        basename = File.basename(uri)
        !list(File.dirname(uri)).find{|entry| File.fnmatch(basename, entry.path)}.nil?
      end

      # check svn uri file exists or not
      # @param [uri string like] uri target uri
      # @return [Boolean] true if exists
      def exist_file?(uri)
        file = File.basename(uri)
        !list_files(File.dirname(uri)).find{|entry| File.fnmatch(file, entry.path)}.nil?
      end

      # svn update
      # @param [path string like] path target path
      # @param [depth] depth --set-depth
      def update(path = ".", depth = nil)
        sys "svn update #{depth ? "--set-depth #{depth}" : ""} #{path}"
      end

      # svn log
      # @param [uri string like] uri target uri
      # @param [Integer] limit --limit
      # @param [Boolean] stop_on_copy --stop-on-copy
      # @return [Array<LogItem>] log (old to new order)
      def log(uri = ".", limit: nil, stop_on_copy: false)
        log = cap "svn log --xml #{limit ? "--limit #{limit}" : ""} #{stop_on_copy ? "--stop-on-copy" : ""} #{uri}"
        LibXML::XML::Document.string(log).find("//log/logentry").map do |entry|
          LogItem.new(
            revision: entry["revision"].to_i,
            author: entry.find_first("author").content,
            date: Time.iso8601(entry.find_first("date").content),
            msg: entry.find_first("msg").content
          )
        end.reverse
      end

      class LogItem
        attr_reader :revision, :author, :date, :msg
        def initialize(revision:, author:, date:, msg:)
          @revision = revision
          @author = author
          @date = date
          @msg = msg
        end
      end

      # head revision of uri
      # @param [uri string like] uri target uri
      # return [Integer] revision number
      def revision(uri = ".")
        log(uri, limit: 1).last.revision
      end

      # stop-on-copy revision of uri
      # @param [uri string like] uri target uri
      # return [Integer] revision number
      def copied_revision(uri = ".")
        log(uri, stop_on_copy: true).first.revision
      end

      # svn update to deep path recursive
      # @param [path string like] path target path
      # @param [Integer] depth --set-depth for only new updated dirs
      # @param [Boolean] exist_path_update middle path update flag
      # @param [String] root working copy root path
      def update_deep(path, depth = nil, exist_path_update = true, root: nil)
        exist_path = path
        until File.exist?(exist_path)
          exist_path = File.dirname(exist_path)
        end
        root = Pathname.new(root || Svn.working_copy_root_path(exist_path))
        end_path = Pathname.new(path.to_s).expand_path
        parents = [end_path]
        while parents.first != root
          parents.unshift(parents.first.parent)
        end
        parents.each do |dir|
          if dir.exist?
            sys "svn update #{dir}" if exist_path_update
          else
            sys "svn update #{depth ? "--set-depth #{depth}" : ""} #{dir}"
          end
        end
      end

      # svn merge -r start_rev:end_rev from_uri to_path
      # @param [Integer] start_rev start revision
      # @param [Integer] end_rev end revision
      # @param [String] from_uri from uri
      # @param [String] to_path to local path
      # @param [String] extra extra options
      def merge1(start_rev, end_rev, from_uri, to_path = ".", extra = "")
        safe_merge merge1_command(start_rev, end_rev, from_uri, to_path, extra)
      end

      # svn merge -r start_rev:end_rev from_uri to_path --dry-run
      # @param [Integer] start_rev start revision
      # @param [Integer] end_rev end revision
      # @param [String] from_uri from uri
      # @param [String] to_path to local path
      # @param [String] extra extra options
      def merge1_dry_run(start_rev, end_rev, from_uri, to_path = ".", extra = "")
        merge_dry_run merge1_command(start_rev, end_rev, from_uri, to_path, extra)
      end

      # "svn merge -r start_rev:end_rev from_uri to_path"
      # @param [Integer] start_rev start revision
      # @param [Integer] end_rev end revision
      # @param [String] from_uri from uri
      # @param [String] to_path to local path
      # @param [String] extra extra options
      # @param [Boolean] dry_run --dry-run
      def merge1_command(start_rev, end_rev, from_uri, to_path = ".", extra = "", dry_run: false)
        "svn merge -r #{start_rev}:#{end_rev} #{from_uri} #{to_path} #{extra} #{dry_run ? "--dry-run" : ""}"
      end

      # merge after dry-run conflict check
      # @param [String] command svn merge full command
      def safe_merge(command)
        dry_run = merge_dry_run(command)
        if dry_run.any? {|entry| entry.status.include?("C")}
          dry_run_str = dry_run.map {|entry| "#{entry.status} #{entry.path}"}.join("\n")
          raise "[ERROR] merge_branch_to_trunk: `#{command}` has conflict!\n#{dry_run_str}"
        else
          sys command
        end
      end

      # merge dry-run conflict check result
      # @param [String] command svn merge full command
      def merge_dry_run(command)
        cap("#{command} --dry-run")
          .each_line.map(&:chomp).reject {|line| line[4] != " "}
          .map {|line| MergeStatusItem.new(status: line[0...4], path: line[5..-1])}
      end

      class MergeStatusItem
        attr_reader :status, :path
        def initialize(status:, path:)
          @status = status
          @path = path
        end
      end

      # svn merge branch to trunk with detecting revision range
      # @param [String] from_uri from uri
      # @param [String] to_path to local path
      def merge_branch_to_trunk(from_uri, to_path = ".")
        start_rev = copied_revision(from_uri)
        end_rev = revision(from_uri)
        merge1(start_rev, end_rev, from_uri, to_path)
      end

      # reverse merge single revision
      # @param [Integer] start_rev start revision
      # @param [Integer] end_rev end revision (if no end_rev then "-c start_rev")
      # @param [String] path local path
      def reverse_merge(start_rev, end_rev = nil, path = ".")
        if end_rev
          safe_merge "svn merge -r #{end_rev}:#{start_rev} #{path}"
        else
          safe_merge "svn merge -c #{start_rev} #{path}"
        end
      end

      # svn info -> yaml parse
      # @param [path string like] path target path
      # @return [Hash<String, String>] svn info contents
      def info(path = ".")
        YAML.load(cap("svn info #{path}"))
      end

      # svn cat
      # @param [path string like] path target path
      # @return [String] file contents
      def cat(path)
        cap("svn cat #{path}")
      end

      # Working Copy Root Path from svn info
      # @param [path string like] path target path
      # @return [String] Working Copy Root Path
      def working_copy_root_path(path = ".")
        info(path)["Working Copy Root Path"]
      end

      # find common part of the given uris
      # @param [Array<uri string like>] uris target uri
      # @return [String] common part of the given uris
      def base_uri_of(uris)
        uris.reduce(Pathname.new(uris.first.to_s)) do |base_uri, uri|
          rel = Pathname.new(uri).relative_path_from(base_uri)
          to_parent = rel.to_s.match(/(?:\.\.\/)*/).to_s
          to_parent.empty? ? base_uri : base_uri + to_parent
        end.to_s
      end

      # svn diff
      # @param [String] from_uri from uri
      # @param [String] to_uri to uri
      # @param [Boolean] ignore_properties --ignore-properties
      # @param [Boolean] ignore_eol_style -x --ignore-eol-style
      # @param [Boolean] ignore_space_change -x --ignore-space-change
      # @param [Boolean] ignore_all_space -x --ignore-all-space
      # @return [String] raw diff str
      def diff(from_uri, to_uri, ignore_properties: false, ignore_eol_style: false, ignore_space_change: false, ignore_all_space: false)
        options = []
        options << "-x --ignore-eol-style" if ignore_eol_style
        options << "-x --ignore-space-change" if ignore_space_change
        options << "-x --ignore-all-space" if ignore_all_space
        options << "--ignore-properties" if ignore_properties
        cap("svn diff #{from_uri} #{to_uri} #{options.join(' ')}")
      end

      # svn diff --summarize
      # @param [String] from_uri from uri
      # @param [String] to_uri to uri
      # @param [Boolean] ignore_properties | grep -v '^ '
      # @param [Boolean] ignore_eol_style -x --ignore-eol-style
      # @param [Boolean] ignore_space_change -x --ignore-space-change
      # @param [Boolean] ignore_all_space -x --ignore-all-space
      # @param [Boolean] with_list_info with svn list info
      # @return [Array] diff files list
      def summarize_diff(from_uri, to_uri, ignore_properties: false, ignore_eol_style: false, ignore_space_change: false, ignore_all_space: false, with_list_info: false)
        options = []
        options << "-x --ignore-eol-style" if ignore_eol_style
        options << "-x --ignore-space-change" if ignore_space_change
        options << "-x --ignore-all-space" if ignore_all_space

        diff_str = cap("svn diff --xml --summarize #{from_uri} #{to_uri} #{options.join(' ')}")
        diff_list = LibXML::XML::Document.string(diff_str).find("//diff/paths/path").map do |path|
          DiffItem.new(
            kind: path["kind"],
            item: path["item"],
            props: path["props"],
            path: path.content
          )
        end
        if ignore_properties
          diff_list.reject! {|diff| diff.item == "none"}
        end
        if with_list_info
          from_entries = Svn.list_recursive(from_uri)
          to_entries = Svn.list_recursive(to_uri)
          from_entries_hash = from_entries.each.with_object({}) {|file, entries_hash| entries_hash[file.path] = file}
          to_entries_hash = to_entries.each.with_object({}) {|file, entries_hash| entries_hash[file.path] = file}
          from_uri_path = Pathname.new(from_uri)
          diff_list.each do |diff|
            path = Pathname.new(diff.path).relative_path_from(from_uri_path).to_s
            diff.from = from_entries_hash[path]
            diff.to = to_entries_hash[path]
          end
        end
        diff_list
      end

      class DiffItem
        attr_reader :kind, :item, :props, :path
        attr_accessor :from, :to
        def initialize(kind:, item:, props:, path:)
          @kind = kind
          @item = item
          @props = props
          @path = path
        end
      end

      # copy single transaction
      # @param [SvnFileCopyTransaction] transaction from and to info
      # @param [String] message commit message
      # @param [Boolean] recursive list --recursive
      def copy_single(transaction, message, recursive = false)
        transactions = transaction.glob_transactions(recursive)
        raise "copy_single: #{transaction.from} not exists" if transactions.empty?
        to_exist_transactions = Svn.list_files(transaction.to_base).map do |entry|
          transactions.find {|_transaction| _transaction.file == entry.path}
        end.compact
        only_from_transactions = transactions - to_exist_transactions
        if to_exist_transactions.empty? # toにファイルがない
          sys "svn copy --parents #{only_from_transactions.map(&:from).join(' ')} #{transaction.to_base} -m '#{message}'"
        else
          Dir.mktmpdir do |dir|
            Dir.chdir(dir) do
              sys "svn checkout --depth empty #{transaction.to_base} ."
              # なくてもエラーにならないので全部update
              sys "svn update --set-depth infinity #{transactions.map(&:file).join(' ')}"
              unless only_from_transactions.empty?
                sys "svn copy --parents #{only_from_transactions.map(&:from).join(' ')} ."
              end
              to_exist_transactions.each do |_transaction|
                begin
                  Svn.merge1(1, "HEAD", _transaction.from, _transaction.file, "--accept theirs-full")
                rescue
                  sys "svn export --force #{_transaction.from} #{_transaction.file}"
                end
              end
              Svn.commit(message, ".")
            end
          end
        end
      end

      # copy multi transactions
      # @param [Array<SvnFileCopyTransaction>] transactions from and to info list
      # @param [String] message commit message
      def copy_multi(transactions, message)
        base_uri = base_uri_of(transactions.map(&:from_base) + transactions.map(&:to_base))
        transactions.each do |transaction|
          raise "copy_multi: #{transaction.from} not exists" unless transaction.from_exist?
        end
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            sys "svn checkout --depth empty #{base_uri} ."
            root = Svn.working_copy_root_path(".")
            transactions.each do |transaction|
              relative_to = transaction.relative_to(base_uri)

              if transaction.to_exist?  # toがある場合マージ
                Svn.update_deep(relative_to, "empty", false, root: root)
                begin
                  Svn.merge1(1, "HEAD", transaction.from, relative_to, "--accept theirs-full")
                rescue
                  sys "svn export --force #{transaction.from} #{relative_to}"
                end
              else # toがない場合コピー
                Svn.update_deep(File.dirname(relative_to), "empty", false, root: root) # mkpath的な なくてもエラーにはならないので
                sys "svn copy --parents #{transaction.from} #{relative_to}"
              end
            end
            Svn.commit(message, ".")
          end
        end
      end

      # check transaction from file exists
      # @param [SvnFileCopyTransaction] transaction from and to info
      # @param [Boolean] raise_if_from_not_found raise if from not found
      # @return [Boolean] true if file exists
      def check_exists(transaction, raise_if_from_not_found = true)
        unless transaction.from_exist?
          if !raise_if_from_not_found
            false
          elsif transaction.to_exist?
            puts "[WARNING] File:#{file}はコピー先のみにあります"
            false
          else
            raise "[Error] File:#{file}が見つかりません！"
          end
        else
          true
        end
      end
    end
  end

  # svn file copy transaction
  # @attr [String] from_base from base uri
  # @attr [String] to_base to base uri
  # @attr [String] file file basename
  class SvnFileCopyTransaction
    attr_reader :from_base
    attr_reader :to_base
    attr_reader :file

    # @param [String] from_base from base uri
    # @param [String] to_base to base uri
    # @param [String] file file basename
    def initialize(from_base:, to_base:, file:)
      @from_base = from_base
      @to_base = to_base
      @file = file
    end

    # from uri
    # @return [String] from uri
    def from
      File.join(@from_base, @file)
    end

    # to uri
    # @return [String] to uri
    def to
      File.join(@to_base, @file)
    end

    # filename glob (like "hoge*") to each single file transaction
    # @param [Boolean] recursive list --recursive
    # @return [Array<SvnFileCopyTransaction>] transactions
    def glob_transactions(recursive = false)
      Svn.list_files(@from_base, recursive)
        .select{|entry| File.fnmatch(@file, entry.path)}
        .map{|entry| SvnFileCopyTransaction.new(from_base: @from_base, to_base: @to_base, file: entry.path)}
    end

    # from uri exists?
    # @return [Boolean]
    def from_exist?
      Svn.exist_file?(from)
    end

    # to uri exists?
    # @return [Boolean]
    def to_exist?
      Svn.exist_file?(to)
    end

    # relative from base path from given base uri
    # @return [String] relative from base path
    def relative_from_base(path)
      Pathname.new(@from_base).relative_path_from(Pathname.new(path)).to_s
    end

    # relative to base path from given base uri
    # @return [String] relative to base path
    def relative_to_base(path)
      Pathname.new(@to_base).relative_path_from(Pathname.new(path)).to_s
    end

    # relative from path from given base uri
    # @return [String] relative from path
    def relative_from(path)
      File.join(relative_from_base(path), @file)
    end

    # relative to path from given base uri
    # @return [String] relative to path
    def relative_to(path)
      File.join(relative_to_base(path), @file)
    end
  end
end
