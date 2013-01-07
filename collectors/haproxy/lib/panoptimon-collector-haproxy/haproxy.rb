require 'panoptimon/util/string-with-as_number'

module Panoptimon
  module Collector
    class HAProxy

      attr_reader :collector, :stats_url

      def initialize(options={})
        url = options[:stats_url] || '/var/run/haproxy.sock'
        @stats_url = url.sub(%r{^socket:/}, '')
        # slash after bare hostname:port
        @stats_url += '/' if @stats_url =~ %r{^https?://[^/]+$}
        @collector = @stats_url !~ %r{^\w+://} \
          ? :stats_from_sock
          : :stats_from_http
      end

      def info
        # stat: frontend,backend,server
        # sys pid, version, uptime_sec, process_num, nbproc
          # :status => status,
          # :_info  => {
          #   :backends  => backends,
          #   :frontends => frontends, 
          #   :servers   => servers,
          #   :pid       => pid,
          #   :version   => version, 
          #   :uptime    => uptime,
          #   :processes => processes, # process_num ?
          #   :nbproc    => nbproc 
          # }
      end

      # check if any frontends, backends, or servers are 'DOWN'
      def status
        [ frontends.values,
          backends.values,
          servers.values].include?('DOWN') ? '0' : '1'
      end

      def self.stats_from_sock(path)
        {
          stats: _parse_stats_csv( _sock_get(path, 'show stat') ),
          info:  _parse_show_info( _sock_get(path, 'show info') )
        }
      end

      def self.stats_from_http(uri)
        # NOTE uri is expected to have trailing slash if needed
        {
          stats: _parse_stats_csv(
            _http_get(uri + ';csv').split(/\n/) ),
          info: _parse_html_info( _http_get(uri) )
        }
      end

      def self._parse_html_info(body)
        body =~ %r{General\sprocess\sinformation</[^>]+>
          (.*?)Running\stasks:\s(\d+)/(\d+)<}xm or
          raise "body: #{body} does not match expectations"
        p = $1
        info = {
          run_queue: $2, # tasks: $3 ?
        }
        # TODO proper dishtml?
        p.gsub!(%r{\s+}, ' ')
        p.gsub!(%r{<br>}, "\n")
        p.gsub!(%r{<[^>]+>}, '')
        p.gsub!(%r{ +}, ' ')
        { # harvest some numbers
          pid:           %r{pid =\s+(\d+)},
          process_num:   %r{process #(\d+)},
          nbproc:        %r{nbproc = (\d+)},
          uptime:        %r{uptime = (\d+d \d+h\d+m\d+s)},
          memmax_mb:     %r{memmax = (unlimited|\d+)},
          :'ulimit-n' => %r{ulimit-n = (\d+)},
          maxsock:       %r{maxsock = (\d+)},
          maxconn:       %r{maxconn = (\d+)},
          maxpipes:      %r{maxpipes = (\d+)},
          currcons:      %r{current conns = (\d+)},
          pipesused:     %r{current pipes = (\d+)/\d+},
          pipesfree:     %r{current pipes = \d+/(\d+)},
        }.each {|k,v|
          got = p.match(v) or raise "no match for #{k} (#{v})"
          info[k] = got[1].as_number || got[1]
        }

        vi = body.match(%r{<body>.*?>([^<]+)\ version\ (\d+\.\d+\.\d+),
          \ released\ (\d{4}/\d{2}/\d{2})}x) or
          raise "failed to find version info"
        info.merge!( name: vi[1], version: vi[2], release_date: vi[3] )
        return info
      end

      def self._http_get(uri)
        require 'net/http'
        uri = URI(uri)
        res = ::Net::HTTP.start(uri.host, uri.port,
          :use_ssl => uri.scheme == 'https'
        ).request(::Net::HTTP::Get.new(uri.request_uri))
        raise "error: #{res.code} #{res.message}" unless
          res.is_a?(::Net::HTTPSuccess)
        return res.body
      end

      def self._parse_show_info(lines)
        Hash[lines.map {|l|
          (k,v) = * l.chomp.split(/:\s+/, 2);
          k or next
          [k.downcase.to_sym, v.as_number || v]}
        ]
      end

      def self._parse_stats_csv(lines)
        head = lines.shift.chomp.sub(/^# /, '') or raise "no header row?"
        hk = head.split(/,/).map {|k| k.to_sym}; hk.shift(2)
        imax = hk.length - 1
        h = Hash.new {|hash,key| hash[key] = {}}
        lines.each {|l| f = l.chomp.split(/,/)
          (n,s) = f.shift(2)
          h[s.to_sym][n] = Hash[(0..imax).map {|i|
            [hk[i], (f[i].nil? or f[i] == "") ? nil :
              f[i].as_number || f[i]]}]
        }
        return h
      end

      def self._sock_get(path, cmd)
        require "socket"
        stat_socket = UNIXSocket.new(path)
        stat_socket.puts(cmd)
        stat_socket.readlines
      end
    end
  end
end
