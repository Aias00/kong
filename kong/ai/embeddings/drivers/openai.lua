-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

--
-- imports
--

local cjson = require("cjson.safe")
local http = require("resty.http")

local gzip = require("kong.tools.gzip")
local build_request = require("kong.ai.embeddings.utils").build_request

local OPENAI_EMBEDDINGS_URL = "https://api.openai.com/v1/embeddings"

--
-- driver object
--

-- Driver is an interface for a openai embeddings driver.
local Driver = {}
Driver.__index = Driver

local function good_embeddings(r)
  return r
     and r.data
     and type(r.data) == "table"
     and #r.data > 0
     and r.data[1].embedding
end

-- Constructs a new Driver
--
-- @param provided_embeddings_config embeddings driver configuration
-- @param dimensions the number of dimensions for generating embeddings
-- @return the Driver object
function Driver:new(c, dimensions)
  c.model = c.model or {}
  c.model.options = c.model.options or {}
  return setmetatable({
    config = {
      model = c.model or {},
      auth = c.auth or {}
    },
    dimensions = dimensions,
  }, Driver)
end

-- Generates the embeddings (vectors) for a given prompt
--
-- @param prompt the prompt to generate embeddings for
-- @return the API response containing the embeddings
-- @return nothing. throws an error if any
function Driver:generate(prompt)
  local embeddings_url = self.config.model.options and
                        self.config.model.options.upstream_url or
                        OPENAI_EMBEDDINGS_URL

  -- prepare prompt for embedding generation
  local body = {
    input      = prompt,
    dimensions = self.dimensions,
    model      = self.config.model.name,
  }

  kong.log.debug("[openai] generating embeddings for prompt")
  local httpc, err = http.new({
    ssl_verify = true,
    ssl_cafile = kong.configuration.lua_ssl_trusted_certificate_combined,
  })
  if not httpc then
    return nil, err
  end


  local headers = {
    ["Content-Type"]    = "application/json",
    ["Accept-Encoding"] = "gzip",  -- explicitly set because OpenAI likes to change this
  }

  embeddings_url, headers, body = build_request(self.config.auth, embeddings_url, headers, body)

  body, err = cjson.encode(body)
  if err then
    return nil, err
  end

  local res, err = httpc:request_uri(embeddings_url, {
    method = "POST",
    headers = headers,
    body = body,
  })
  if not res then
    return nil, string.format("failed to generate embeddings (%s): %s", embeddings_url, err)
  end
  if res.status ~= 200 then
    return nil, string.format("unexpected embeddings response (%s): %s", embeddings_url, res.status)
  end

  local res_body = res.body
  if res.headers["Content-Encoding"] == "gzip" then
    res_body = gzip.inflate_gzip(res_body)
  end

  local embedding_response, err = cjson.decode(res_body)
  if err then
    return nil, err
  end

  -- validate if there are embeddings in the response
  if #embedding_response.data == 0 then
    return nil, "no embeddings found in response"
  end

  if not good_embeddings(embedding_response) then
    return nil, "embeddings response does not contain any vectors"
  end

  return embedding_response.data[1].embedding, nil
end

--
-- module
--

return Driver
