--- @classmod Upstream
-- Abstracts how to forward traffic to upstream server.
--- @usage
--- local upstream = Upstream.new('http://example.com')
--- upstream:set_request_host() -- set Host header to 'example.com'
--- -- store itself in `context` table for later use in balancer phase and call `ngx.exec`.
--- upstream:call(context)

local setmetatable = setmetatable
local tonumber = tonumber
local str_format = string.format

local resty_resolver = require('resty.resolver')
local resty_url = require('resty.url')
local core_base = require('resty.core.base')
local new_tab = core_base.new_tab

local _M = {

}

local function proxy_pass(upstream)
    local uri = upstream.uri

    return str_format('%s://%s%s%s%s',
            uri.scheme,
            upstream.upstream_name,
            uri.path or ngx.var.uri or '',
            ngx.var.is_args or '',
            ngx.var.query_string or '')
end

local mt = {
    __index = _M
}


local function parse_url(url)
    local parsed, err = resty_url.split(url)

    if err then return nil, err end

    local uri = new_tab(0, 6)

    uri.scheme = parsed[1]
    uri.user = parsed[2]
    uri.password = parsed[3]
    uri.host = parsed[4]
    uri.port = tonumber(parsed[5])
    uri.path = parsed[6]

    return uri
end


--- Create new Upstream instance.
--- @tparam string url
--- @treturn Upstream|nil upstream instance
--- @treturn nil|string error when upstream can't be initialized
--- @static
function _M.new(url)
    local uri, err = parse_url(url)

    if err then
        return nil, 'invalid upstream'
    end

    return setmetatable({
        uri = uri,
        resolver = resty_resolver,
        -- @upstream location is defined in apicast.conf
        location_name = '@upstream',
        -- upstream is defined in upstream.conf
        upstream_name = 'upstream',
    }, mt)
end

--- Resolve upstream servers.
--- @treturn {...}|nil resolved servers returned by the resolver
--- @treturn nil|string error in case resolving fails
function _M:resolve()
    local resolver = self.resolver
    local uri = self.uri

    if self.servers then
        return self.servers
    end

    if not resolver or not uri then return nil, 'not initialized' end

    local res, err = resolver:instance():get_servers(uri.host, uri)

    if err then
        return nil, err
    end

    self.servers = res

    return res
end

--- Return port to use when connecting to upstream.
--- @treturn number port number
function _M:port()
    if not self or not self.uri then
        return nil, 'not initialized'
    end

    return self.uri.port or resty_url.default_port(self.uri.scheme)
end

--- Rewrite request Host header to what is provided in the argument or in the URL.
--- @tparam string host Host header of the request
function _M:set_request_host(host)
    ngx.req.set_header('Host', host or self.uri.host)
end

local function exec(self)
    ngx.var.proxy_pass = proxy_pass(self)

    -- the caller can unset the location_name to do own exec/location.capture
    if self.location_name then
        ngx.exec(self.location_name)
    end
end

--- Execute the upstream.
--- @tparam table context any table (policy context, ngx.ctx) to store the upstream for later use by balancer
function _M:call(context)
    if ngx.headers_sent then return nil, 'response sent already' end

    if not self.servers then self:resolve() end

    context[self.upstream_name] = self

    return exec(self)
end

return _M
