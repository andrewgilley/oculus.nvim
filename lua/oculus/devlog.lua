-- A tracked project's official devlog: finding its feed, reading the posts in
-- it, and rendering a post's HTML into plain lines that mark the pull
-- requests, issues and commits the post refers to so they can be inspected.
local patch = require("oculus.inspect.patch")
local M = {}

local user_agent = "oculus.nvim (+https://github.com/andrewgilley/oculus.nvim)"
local feed_cache = {}
local page_cache = {}
local discovery_cache = {}

-- Paths tried, in order, on a project's homepage when the page itself does not
-- advertise a feed.
M.feed_paths = {
  "/devlog/index.xml",
  "/devlog/feed.xml",
  "/devlog/rss.xml",
  "/blog/atom.xml",
  "/blog/rss.xml",
  "/blog/index.xml",
  "/blog/feed.xml",
  "/news/index.xml",
  "/news.xml",
  "/feed.xml",
  "/atom.xml",
  "/rss.xml",
  "/index.xml",
}

-- Text shorter than this in a feed's description is taken to be an excerpt,
-- so the post's own page is fetched for the full text.
local full_description_length = 1000

function M.project_key(project)
  return (project.provider == "codeberg" and "codeberg" or "github")
    .. ":"
    .. tostring(project.repository or ""):lower()
end

local function utf8_char(code)
  if code < 0 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then
    return ""
  elseif code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  elseif code < 0x10000 then
    return string.char(
      0xE0 + math.floor(code / 0x1000),
      0x80 + math.floor(code / 0x40) % 0x40,
      0x80 + code % 0x40
    )
  end

  return string.char(
    0xF0 + math.floor(code / 0x40000),
    0x80 + math.floor(code / 0x1000) % 0x40,
    0x80 + math.floor(code / 0x40) % 0x40,
    0x80 + code % 0x40
  )
end

local named_entities = {
  amp = "&",
  lt = "<",
  gt = ">",
  quot = '"',
  apos = "'",
  nbsp = " ",
  ensp = " ",
  emsp = " ",
  thinsp = " ",
  ndash = "–",
  mdash = "—",
  hellip = "…",
  lsquo = "‘",
  rsquo = "’",
  ldquo = "“",
  rdquo = "”",
  laquo = "«",
  raquo = "»",
  bull = "•",
  middot = "·",
  copy = "©",
  reg = "®",
  trade = "™",
  times = "×",
  deg = "°",
  larr = "←",
  rarr = "→",
  uarr = "↑",
  darr = "↓",
  shy = "",
  zwj = "",
  zwnj = "",
}

function M.decode_entities(text)
  if type(text) ~= "string" or not text:find("&", 1, true) then
    return text
  end

  return (text:gsub("&(#?)([xX]?)(%w+);", function(numeric, hex, body)
    if numeric == "#" then
      local code = tonumber(body, hex ~= "" and 16 or 10)
      return code and utf8_char(code) or nil
    end

    if hex ~= "" then
      return nil
    end

    return named_entities[body] or named_entities[body:lower()]
  end))
end

local function collapse(text)
  return vim.trim((text or ""):gsub("%s+", " "))
end

-- Resolve a link found on the page at `base` to an absolute URL.
function M.resolve_url(href, base)
  if type(href) ~= "string" then
    return nil
  end

  href = vim.trim(href)

  if href == "" then
    return nil
  end

  if href:match("^%a[%w+.-]*:") then
    return href
  end

  local scheme, host = (base or ""):match("^(%a[%w+.-]*://)([^/?#]*)")

  if not scheme then
    return href
  end

  if href:sub(1, 2) == "//" then
    return scheme:sub(1, -3) .. href
  end

  local path = base:sub(#scheme + #host + 1)

  if href:sub(1, 1) == "#" then
    return scheme .. host .. path:gsub("#.*$", "") .. href
  end

  if href:sub(1, 1) == "?" then
    return scheme .. host .. path:gsub("[?#].*$", "") .. href
  end

  if href:sub(1, 1) ~= "/" then
    local directory = path:gsub("[?#].*$", ""):match("^(.*/)") or "/"
    href = directory .. href
  end

  local suffix = href:match("[?#].*$") or ""
  local segments = vim.split(href:sub(1, #href - #suffix), "/", { plain = true })
  local normalized = {}

  for index, segment in ipairs(segments) do
    if segment == ".." then
      if #normalized > 1 then
        normalized[#normalized] = nil
      end
    elseif segment ~= "." or index == #segments then
      normalized[#normalized + 1] = segment == "." and "" or segment
    end
  end

  return scheme .. host .. table.concat(normalized, "/") .. suffix
end

local function host_of(url)
  return type(url) == "string" and url:match("^%a[%w+.-]*://([^/?#]+)") or nil
end

-- The feed's address without its scheme, e.g. "ziglang.org/devlog/index.xml".
function M.display_url(url)
  return (tostring(url or ""):gsub("^%a[%w+.-]*://", ""):gsub("/$", ""))
end

local function request(url, opts, callback, timeout)
  if vim.fn.executable("curl") ~= 1 then
    vim.schedule(function()
      callback(nil, "Oculus requires curl to load devlogs")
    end)

    return
  end

  local command = {
    "curl",
    "-sS",
    "-L",
    "--compressed",
    "--max-time",
    tostring(timeout or opts.request_timeout or 15),
    "-A",
    user_agent,
    "-w",
    "\n%{http_code}",
    url,
  }

  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local message = vim.trim(result.stderr or "")
        callback(nil, message ~= "" and message or ("Unable to reach " .. (host_of(url) or url)))
        return
      end

      local body, status = (result.stdout or ""):match("^(.*)\n(%d%d%d)%s*$")

      if not status then
        callback(nil, (host_of(url) or url) .. " returned an invalid response")
        return
      end

      if tonumber(status) >= 400 then
        callback(nil, ("HTTP %s from %s"):format(status, host_of(url) or url))
        return
      end

      callback(body)
    end)
  end)
end

local function attributes(text)
  local attrs = {}
  local pos = 1
  local len = #(text or "")

  while pos <= len do
    local _, finish, name = text:find("^[%s/]*([^%s=/>]+)", pos)

    if not finish then
      break
    end

    pos = finish + 1
    local value = ""
    local equals = text:match("^%s*=%s*", pos)

    if equals then
      pos = pos + #equals
      local quote = text:sub(pos, pos)

      if quote == '"' or quote == "'" then
        local close = text:find(quote, pos + 1, true) or (len + 1)
        value = text:sub(pos + 1, close - 1)
        pos = close + 1
      else
        value = text:match("^[^%s>]*", pos)
        pos = pos + #value
      end
    end

    attrs[name:lower()] = M.decode_entities(value)
  end

  return attrs
end

M._attributes = attributes

-- Feed parsing ---------------------------------------------------------------

-- CDATA sections are taken as they are; everything else in an XML element is
-- entity-escaped.
local function xml_text(value)
  if not value then
    return nil
  end

  local parts = {}
  local pos = 1

  while true do
    local start, finish, inner = value:find("<!%[CDATA%[(.-)%]%]>", pos)

    if not start then
      parts[#parts + 1] = M.decode_entities(value:sub(pos))
      break
    end

    parts[#parts + 1] = M.decode_entities(value:sub(pos, start - 1))
    parts[#parts + 1] = inner
    pos = finish + 1
  end

  return table.concat(parts)
end

-- Every `<name>` element directly in `block`: its attributes and raw content.
local function xml_elements(block, name)
  local found = {}
  local pos = 1
  local open = "<" .. vim.pesc(name) .. "%f[%s/>]"
  local close = "</" .. vim.pesc(name) .. "%s*>"

  while true do
    local start = block:find(open, pos)

    if not start then
      break
    end

    local tag_finish = block:find(">", start, true)

    if not tag_finish then
      break
    end

    local tag = block:sub(start + #name + 1, tag_finish - 1)
    local entry = { attrs = attributes(tag), content = "" }

    if tag:match("/%s*$") then
      pos = tag_finish + 1
    else
      local close_start, close_finish = block:find(close, tag_finish + 1)

      if not close_start then
        break
      end

      entry.content = block:sub(tag_finish + 1, close_start - 1)
      pos = close_finish + 1
    end

    found[#found + 1] = entry
  end

  return found
end

local function xml_element(block, name)
  return xml_elements(block, name)[1]
end

local function xml_value(block, ...)
  for _, name in ipairs({ ... }) do
    local element = xml_element(block, name)

    if element then
      local value = xml_text(element.content)

      if value and vim.trim(value) ~= "" then
        return value, element
      end
    end
  end

  return nil
end

local month_numbers = {
  jan = 1,
  feb = 2,
  mar = 3,
  apr = 4,
  may = 5,
  jun = 6,
  jul = 7,
  aug = 8,
  sep = 9,
  oct = 10,
  nov = 11,
  dec = 12,
}

-- An RSS (RFC 822) or Atom (ISO 8601) date as "YYYY-MM-DDTHH:MM:SS".
function M.parse_date(value)
  if type(value) ~= "string" then
    return nil
  end

  local year, month, day, rest = value:match("(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)")

  if year then
    local hour, minute, second = rest:match("^[T ](%d%d):(%d%d):?(%d*)")

    return ("%s-%s-%sT%s:%s:%s"):format(
      year,
      month,
      day,
      hour or "00",
      minute or "00",
      second ~= nil and second ~= "" and second or "00"
    )
  end

  local day_number, month_name, full_year, time =
    value:match("(%d%d?)%s+(%a%a%a)%a*%.?%s+(%d%d%d?%d?)%s*(.*)")

  -- "August 27, 2026"
  if not (month_name and month_numbers[month_name:lower()]) then
    month_name, day_number, full_year = value:match("(%a%a%a)%a*%.?%s+(%d%d?)%a*,?%s+(%d%d%d%d)")
    time = ""
  end

  local month_number = month_name and month_numbers[month_name:lower()]

  if not month_number then
    return nil
  end

  local numeric_year = tonumber(full_year)

  if numeric_year < 100 then
    numeric_year = numeric_year + (numeric_year < 70 and 2000 or 1900)
  end

  local hour, minute, second = (time or ""):match("^(%d%d?):(%d%d):?(%d*)")

  return ("%04d-%02d-%02dT%02d:%02d:%02d"):format(
    numeric_year,
    month_number,
    tonumber(day_number),
    tonumber(hour) or 0,
    tonumber(minute) or 0,
    tonumber(second) or 0
  )
end

local text_breaks = {
  br = true,
  p = true,
  div = true,
  li = true,
  ul = true,
  ol = true,
  h1 = true,
  h2 = true,
  h3 = true,
  h4 = true,
  h5 = true,
  h6 = true,
  tr = true,
  td = true,
  th = true,
  dt = true,
  dd = true,
  blockquote = true,
  section = true,
  article = true,
  figure = true,
  figcaption = true,
  table = true,
  hr = true,
}

-- The prose of an HTML fragment on one line: code blocks, scripts and styles
-- are left out, and inline tags vanish without splitting the words around
-- them.
local function strip_tags(html)
  local text = (html or "")
    :gsub("<!%-%-.-%-%->", "")
    :gsub("<[pP][rR][eE][%s>].-</[pP][rR][eE]%s*>", " ")
    :gsub("<[sS][cC][rR][iI][pP][tT][%s>].-</[sS][cC][rR][iI][pP][tT]%s*>", " ")
    :gsub("<[sS][tT][yY][lL][eE][%s>].-</[sS][tT][yY][lL][eE]%s*>", " ")
    :gsub("<(/?)(%a%w*)[^>]*>", function(_, tag)
      return text_breaks[tag:lower()] and " " or ""
    end)

  return collapse(M.decode_entities(text))
end

local function has_block_markup(html)
  return html:find("<[pP][%s>]") or html:find("<pre[%s>]") or html:find("<h%d[%s>]")
end

local function atom_link(block)
  local fallback

  for _, link in ipairs(xml_elements(block, "link")) do
    local rel = link.attrs.rel or "alternate"

    if link.attrs.href and rel == "alternate" then
      if not link.attrs.type or link.attrs.type:find("html", 1, true) then
        return link.attrs.href
      end

      fallback = fallback or link.attrs.href
    end
  end

  return fallback
end

local function feed_post(block, atom, feed_url)
  local title = strip_tags(xml_value(block, "title") or "")
  local link

  if atom then
    link = atom_link(block)
  else
    link = xml_value(block, "link")

    if not link then
      local guid, element = xml_value(block, "guid")

      if guid and (element.attrs.ispermalink or "true") ~= "false" then
        link = guid
      end
    end
  end

  link = M.resolve_url(link and vim.trim(link), feed_url)
  local timestamp = M.parse_date(xml_value(block, "pubDate", "published", "updated", "dc:date"))
  local authors = {}

  if atom then
    for _, author in ipairs(xml_elements(block, "author")) do
      local name = xml_value(author.content, "name")

      if name then
        authors[#authors + 1] = collapse(name)
      end
    end
  else
    local author = xml_value(block, "dc:creator", "author")

    if author then
      -- RSS authors are often "email (Name)".
      authors[1] = collapse(author:match("%((.-)%)%s*$") or author)
    end
  end

  local content = xml_value(block, "content:encoded")
  local content_element

  if atom then
    content, content_element = xml_value(block, "content")

    if content and content_element.attrs.type == "text" then
      content = "<p>"
        .. content:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub("\n%s*\n", "</p><p>")
        .. "</p>"
    end
  end

  local excerpt = xml_value(block, atom and "summary" or "description")

  -- A description that is a whole article is as good as the post's page.
  if not content
    and excerpt
    and has_block_markup(excerpt)
    and #strip_tags(excerpt) >= full_description_length
  then
    content = excerpt
  end

  -- Some devlogs name the author in the post's first paragraph instead.
  if #authors == 0 then
    local byline = (content or excerpt or ""):match("<p>%s*Author:%s*(.-)</p>")

    if byline then
      authors[1] = strip_tags(byline)
    end
  end

  local id = collapse(xml_value(block, atom and "id" or "guid") or "")

  return {
    id = id ~= "" and id or link or title,
    title = title ~= "" and title or (link or "Untitled post"),
    url = link,
    timestamp = timestamp,
    date = timestamp and timestamp:sub(1, 10) or nil,
    author = #authors > 0 and table.concat(authors, ", ") or nil,
    content = content,
    excerpt = excerpt,
  }
end

-- Parse an RSS or Atom document into { title, link, posts }, newest first.
function M.parse_feed(xml, feed_url)
  if type(xml) ~= "string" then
    return nil, "the devlog feed is empty"
  end

  local atom = xml:find("<feed[%s>]") ~= nil and not xml:find("<rss[%s>]")
  local item_name = atom and "entry" or "item"

  if not atom and not xml:find("<rss[%s>]") and not xml:find("<rdf:RDF[%s>]") then
    return nil, "not an RSS or Atom feed"
  end

  local posts = {}

  for _, item in ipairs(xml_elements(xml, item_name)) do
    posts[#posts + 1] = feed_post(item.content, atom, feed_url)
  end

  -- The feed's own title and link sit before its first item.
  local head = xml:sub(1, (xml:find("<" .. item_name .. "[%s>]") or #xml + 1) - 1)

  for index, post in ipairs(posts) do
    post.order = index
  end

  table.sort(posts, function(left, right)
    if left.timestamp and right.timestamp and left.timestamp ~= right.timestamp then
      return left.timestamp > right.timestamp
    end

    return left.order < right.order
  end)

  return {
    title = strip_tags(xml_value(head, "title") or ""),
    link = M.resolve_url(atom and atom_link(head) or xml_value(head, "link"), feed_url),
    posts = posts,
  }
end

-- HTML parsing ---------------------------------------------------------------

local void_elements = {
  area = true,
  base = true,
  br = true,
  col = true,
  embed = true,
  hr = true,
  img = true,
  input = true,
  link = true,
  meta = true,
  param = true,
  source = true,
  track = true,
  wbr = true,
}

local raw_text_elements = {
  script = true,
  style = true,
  textarea = true,
  title = true,
}

local closes_paragraph = {
  address = true,
  article = true,
  aside = true,
  blockquote = true,
  div = true,
  dl = true,
  figure = true,
  footer = true,
  h1 = true,
  h2 = true,
  h3 = true,
  h4 = true,
  h5 = true,
  h6 = true,
  header = true,
  hr = true,
  main = true,
  nav = true,
  ol = true,
  p = true,
  pre = true,
  section = true,
  table = true,
  ul = true,
}

-- Opening one of these closes an open sibling of the listed kinds, up to the
-- nearest container of the listed kinds.
local implied_closes = {
  li = { close = { li = true }, stop = { ul = true, ol = true } },
  dt = { close = { dt = true, dd = true }, stop = { dl = true } },
  dd = { close = { dt = true, dd = true }, stop = { dl = true } },
  tr = { close = { tr = true, td = true, th = true }, stop = { table = true, tbody = true, thead = true, tfoot = true } },
  td = { close = { td = true, th = true }, stop = { tr = true } },
  th = { close = { td = true, th = true }, stop = { tr = true } },
  option = { close = { option = true }, stop = { select = true } },
}

local function tag_end(html, start)
  local pos = start + 1

  while true do
    local found, _, char = html:find("([>\"'])", pos)

    if not found then
      return #html
    end

    if char == ">" then
      return found
    end

    local close = html:find(char, found + 1, true)

    if not close then
      return #html
    end

    pos = close + 1
  end
end

local function case_insensitive(text)
  return (text:gsub("%a", function(char)
    return "[" .. char:lower() .. char:upper() .. "]"
  end))
end

-- Parse HTML into a tree of { tag, attrs, children } and { text } nodes,
-- tolerating the unclosed and misnested tags real pages contain.
function M.parse_html(html)
  local root = { tag = "#root", attrs = {}, children = {} }
  local stack = { root }
  local pos = 1
  local len = #(html or "")

  local function append(node)
    local children = stack[#stack].children
    children[#children + 1] = node
  end

  local function add_text(text)
    if text ~= "" then
      append({ text = M.decode_entities(text) })
    end
  end

  local function close(name)
    for index = #stack, 2, -1 do
      if stack[index].tag == name then
        for remove = #stack, index, -1 do
          stack[remove] = nil
        end

        return
      end
    end
  end

  local function close_implied(name)
    local rule = implied_closes[name]

    if rule then
      for index = #stack, 2, -1 do
        local tag = stack[index].tag

        if rule.stop[tag] then
          break
        end

        if rule.close[tag] then
          for remove = #stack, index, -1 do
            stack[remove] = nil
          end

          break
        end
      end
    end

    if closes_paragraph[name] then
      for index = #stack, 2, -1 do
        local tag = stack[index].tag

        if tag == "p" then
          for remove = #stack, index, -1 do
            stack[remove] = nil
          end

          break
        elseif tag ~= "a" and tag ~= "span" and tag ~= "em" and tag ~= "strong" and tag ~= "b" and tag ~= "i" then
          break
        end
      end
    end
  end

  while pos <= len do
    local lt = html:find("<", pos, true)

    if not lt then
      add_text(html:sub(pos))
      break
    end

    add_text(html:sub(pos, lt - 1))

    if html:sub(lt, lt + 3) == "<!--" then
      local finish = html:find("-->", lt + 4, true)
      pos = finish and finish + 3 or len + 1
    elseif html:sub(lt, lt + 8) == "<![CDATA[" then
      local finish = html:find("]]>", lt + 9, true)
      append({ text = html:sub(lt + 9, (finish or len + 1) - 1) })
      pos = finish and finish + 3 or len + 1
    else
      local closing, name = html:match("^<(/?)(%a[%w:-]*)", lt)

      if not name then
        local special = html:sub(lt + 1, lt + 1)

        if special == "!" or special == "?" then
          local finish = html:find(">", lt, true)
          pos = finish and finish + 1 or len + 1
        else
          add_text("<")
          pos = lt + 1
        end
      else
        local finish = tag_end(html, lt)
        local inner = html:sub(lt + 1 + #closing + #name, finish - 1)
        pos = finish + 1
        name = name:lower()

        if closing == "/" then
          if name == "br" then
            append({ tag = "br", attrs = {}, children = {} })
          else
            close(name)
          end
        else
          close_implied(name)
          local node = { tag = name, attrs = attributes(inner), children = {} }
          append(node)

          if raw_text_elements[name] then
            local close_start, close_finish =
              html:find("</" .. case_insensitive(name) .. "%s*>", pos)

            node.children[1] = {
              text = M.decode_entities(html:sub(pos, (close_start or len + 1) - 1)),
            }

            pos = close_finish and close_finish + 1 or len + 1
          elseif not void_elements[name] and not inner:match("/%s*$") then
            stack[#stack + 1] = node
          end
        end
      end
    end
  end

  return root
end

local function find_node(node, predicate)
  if node.tag and predicate(node) then
    return node
  end

  for _, child in ipairs(node.children or {}) do
    local found = child.tag and find_node(child, predicate)

    if found then
      return found
    end
  end

  return nil
end

local function has_class(node, pattern)
  local classes = " " .. (node.attrs.class or "") .. " "
  return classes:find(pattern) ~= nil
end

-- The part of a page holding the post: the element the URL's fragment names,
-- else the article, else the main content, else the whole body.
function M.main_content(tree, url)
  local fragment = type(url) == "string" and url:match("#(.+)$")

  if fragment then
    local target = find_node(tree, function(node)
      return node.attrs.id == fragment
    end)

    -- An anchor on a heading names the section it opens: the heading and what
    -- follows it up to the next heading of the same or a higher level.
    if target and target.tag:match("^h%d$") then
      local parent = find_node(tree, function(node)
        return vim.tbl_contains(node.children, target)
      end)

      if parent then
        local level = tonumber(target.tag:sub(2))
        local section = { tag = "div", attrs = {}, children = {} }
        local inside = false

        for _, child in ipairs(parent.children) do
          if child == target then
            inside = true
          elseif inside and child.tag and child.tag:match("^h%d$") and tonumber(child.tag:sub(2)) <= level then
            break
          end

          if inside then
            section.children[#section.children + 1] = child
          end
        end

        return section
      end
    end

    if target then
      return target
    end
  end

  local candidates = {
    function(node)
      return node.tag == "article"
    end,
    function(node)
      return node.tag == "main" or node.attrs.role == "main"
    end,
    function(node)
      return has_class(node, "[%s]post%-content[%s]")
        or has_class(node, "[%s]entry%-content[%s]")
        or has_class(node, "[%s]article%-content[%s]")
        or has_class(node, "[%s]post%-body[%s]")
        or has_class(node, "[%s]markdown%-body[%s]")
    end,
    function(node)
      return node.tag == "body"
    end,
  }

  for _, predicate in ipairs(candidates) do
    local found = find_node(tree, predicate)

    if found then
      return found
    end
  end

  return tree
end

-- References ------------------------------------------------------------------

local function forge_host(provider)
  return provider == "codeberg" and "codeberg.org" or "github.com"
end

local function tracked_project(repository, projects)
  for _, project in ipairs(projects or {}) do
    if type(project) == "table"
      and type(project.repository) == "string"
      and project.repository:lower() == repository:lower()
    then
      return project
    end
  end

  return nil
end

-- An inspectable reference for a forge URL, or nil when the URL is not a pull
-- request, issue or commit.
function M.url_reference(url)
  local info = patch.parse_target_url(url)

  if not info then
    return nil
  end

  local repository = info.owner .. "/" .. info.repo
  local label

  if info.kind == "commit" then
    label = repository .. "@" .. info.sha:sub(1, 10)
  else
    label = repository .. "#" .. tostring(info.number)
  end

  return {
    url = url,
    kind = info.kind,
    forge = info.forge,
    repository = repository,
    label = label,
    segments = {},
  }
end

-- A reference written as "owner/repo#123", or "#123" in the post's project.
function M.number_reference(repository, number, projects)
  local project = tracked_project(repository, projects)
  local provider = project and project.provider or "github"

  return {
    target = repository .. "#" .. number,
    project = project,
    forge = provider,
    repository = repository,
    label = repository .. "#" .. number,
    -- Both forges redirect an issue URL to the pull request with that number.
    web_url = ("https://%s/%s/issues/%s"):format(forge_host(provider), repository, number),
    segments = {},
  }
end

-- The references, and plain links, written out in `text`: forge URLs,
-- "owner/repo#123" and, when the post belongs to a project, "#123". Each is
-- { start, finish, reference?, url? } with byte offsets into `text`.
function M.text_references(text, project, projects)
  local matches = {}

  for start, url in text:gmatch("()(https?://[%w%-._~:/?#%[%]@!$&'*+,;=%%()]+)") do
    url = url:gsub("[.,;:!?'%)%]]+$", "")

    -- Keep a closing parenthesis the URL opened itself.
    if url:find("(", 1, true) and text:sub(start + #url, start + #url) == ")" then
      url = url .. ")"
    end

    local reference = M.url_reference(url)

    matches[#matches + 1] = {
      start = start,
      finish = start + #url - 1,
      reference = reference,
      url = url,
    }
  end

  for start, repository, number in text:gmatch("()([%w][%w_.%-]*/[%w_.%-]+)#(%d+)") do
    local before = start > 1 and text:sub(start - 1, start - 1) or ""

    if not before:match("[%w/.:%-]") then
      matches[#matches + 1] = {
        start = start,
        finish = start + #repository + #number,
        reference = M.number_reference(repository, number, projects),
      }
    end
  end

  if project and type(project.repository) == "string" then
    for start, number, after in text:gmatch("()#(%d%d+)()") do
      local before = start > 1 and text:sub(start - 1, start - 1) or ""
      local next_char = text:sub(after, after)

      if not before:match("[%w&/#]") and not next_char:match("[%w_]") then
        matches[#matches + 1] = {
          start = start,
          finish = after - 1,
          reference = M.number_reference(project.repository, number, projects),
        }
      end
    end
  end

  table.sort(matches, function(left, right)
    if left.start ~= right.start then
      return left.start < right.start
    end

    return left.finish > right.finish
  end)

  local result = {}
  local covered = 0

  for _, match in ipairs(matches) do
    if match.start > covered then
      result[#result + 1] = match
      covered = match.finish
    end
  end

  return result
end

-- Rendering -------------------------------------------------------------------

local skipped_elements = {
  script = true,
  style = true,
  noscript = true,
  template = true,
  svg = true,
  nav = true,
  header = true,
  footer = true,
  aside = true,
  form = true,
  button = true,
  input = true,
  select = true,
  textarea = true,
  iframe = true,
  head = true,
  title = true,
  meta = true,
  link = true,
}

local inline_groups = {
  strong = "OculusDevlogStrong",
  b = "OculusDevlogStrong",
  em = "OculusDevlogEmphasis",
  i = "OculusDevlogEmphasis",
  cite = "OculusDevlogEmphasis",
  code = "OculusDevlogCode",
  kbd = "OculusDevlogCode",
  samp = "OculusDevlogCode",
  tt = "OculusDevlogCode",
  mark = "OculusDevlogStrong",
}

local heading_elements = { h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true }

local spaced_blocks = {
  p = true,
  pre = true,
  blockquote = true,
  ul = true,
  ol = true,
  dl = true,
  table = true,
  figure = true,
  hr = true,
  details = true,
}

local block_elements = vim.tbl_extend("force", {}, closes_paragraph, spaced_blocks, {
  li = true,
  dt = true,
  dd = true,
  tr = true,
  figcaption = true,
  summary = true,
  body = true,
  center = true,
  tbody = true,
  thead = true,
  tfoot = true,
})

local function display_width(text)
  return vim.api.nvim_strwidth(text)
end

local function node_text(node, parts)
  parts = parts or {}

  if node.text then
    parts[#parts + 1] = node.text
  elseif node.tag == "br" then
    parts[#parts + 1] = "\n"
  elseif not skipped_elements[node.tag] then
    for _, child in ipairs(node.children or {}) do
      node_text(child, parts)
    end
  end

  return parts
end

local Renderer = {}
Renderer.__index = Renderer

local function new_renderer(opts)
  return setmetatable({
    width = math.max(20, opts.width or 80),
    base_url = opts.base_url,
    project = opts.project,
    projects = opts.projects,
    skip_title = opts.skip_title and collapse(opts.skip_title):lower() or nil,
    skip_byline = opts.author and ("author: " .. collapse(opts.author):lower()) or nil,
    lines = {},
    highlights = {},
    links = {},
    references = {},
    runs = {},
    pending_blank = false,
    seen_content = false,
  }, Renderer)
end

function Renderer:emit(text)
  self.lines[#self.lines + 1] = text
  return #self.lines
end

function Renderer:blank_if_pending()
  if self.pending_blank and #self.lines > 0 and self.lines[#self.lines] ~= "" then
    self:emit("")
  end

  self.pending_blank = false
end

function Renderer:highlight(line, start, finish, group)
  if group and finish > start then
    self.highlights[#self.highlights + 1] = { line, start, finish, group }
  end
end

function Renderer:add_segment(reference, line, start, finish)
  if #reference.segments == 0 then
    self.references[#self.references + 1] = reference
  end

  local last = reference.segments[#reference.segments]

  -- Words of one link on the same line read as a single stretch.
  if last and last.line == line and start - last.finish <= 1 then
    last.finish = finish
    return
  end

  reference.segments[#reference.segments + 1] = {
    line = line,
    start = start,
    finish = finish,
  }
end

function Renderer:add_link(url, line, start, finish)
  local last = self.links[#self.links]

  if last and last.url == url and last.line == line and start - last.finish <= 1 then
    last.finish = finish
    return
  end

  self.links[#self.links + 1] = { url = url, line = line, start = start, finish = finish }
end

function Renderer:push_run(text, ctx)
  if text == "" then
    return
  end

  self.runs[#self.runs + 1] = {
    text = text,
    group = ctx.group,
    href = ctx.href,
    reference = ctx.reference,
    code = ctx.code,
  }
end

-- Split a run of prose into the references written out in it and the text
-- between them.
local function expand_run(run, project, projects)
  if run.reference or run.href or run.code or run.br then
    return { run }
  end

  local matches = M.text_references(run.text, project, projects)

  if #matches == 0 then
    return { run }
  end

  local result = {}
  local pos = 1

  for _, match in ipairs(matches) do
    if match.start > pos then
      result[#result + 1] = { text = run.text:sub(pos, match.start - 1), group = run.group }
    end

    result[#result + 1] = {
      text = run.text:sub(match.start, match.finish),
      group = run.group,
      href = match.reference and match.reference.url or match.url,
      reference = match.reference,
    }

    pos = match.finish + 1
  end

  if pos <= #run.text then
    result[#result + 1] = { text = run.text:sub(pos), group = run.group }
  end

  return result
end

-- Lay the collected inline runs out as a wrapped paragraph.
function Renderer:flush(ctx)
  local runs = self.runs
  self.runs = {}

  local pieces = {}
  local space = false

  for _, source in ipairs(runs) do
    for _, run in ipairs(expand_run(source, self.project, self.projects)) do
      if run.br then
        pieces[#pieces + 1] = { br = true }
        space = false
      else
        local pos = 1

        while pos <= #run.text do
          local gap_start, gap_finish = run.text:find("^%s+", pos)

          if gap_start then
            space = true
            pos = gap_finish + 1
          else
            local word = run.text:match("^%S+", pos)
            pieces[#pieces + 1] = { text = word, run = run, space = space }
            space = false
            pos = pos + #word
          end
        end
      end
    end
  end

  -- Drop leading breaks and see whether anything is left to show.
  while pieces[1] and pieces[1].br do
    table.remove(pieces, 1)
  end

  if #pieces == 0 then
    return
  end

  local text = {}

  for _, piece in ipairs(pieces) do
    text[#text + 1] = piece.text or " "
  end

  local plain = collapse(table.concat(text, " "))

  -- The header above the post already shows its title and author.
  if not self.seen_content then
    if self.skip_title and ctx.heading and plain:lower() == self.skip_title then
      self.skip_title = nil
      return
    end

    if self.skip_byline and plain:lower() == self.skip_byline then
      self.skip_byline = nil
      return
    end
  end

  self.seen_content = true
  self:blank_if_pending()

  -- Group pieces into words: pieces with no space between them wrap together.
  local words = {}

  for _, piece in ipairs(pieces) do
    if piece.br then
      words[#words + 1] = { br = true }
    elseif piece.space or #words == 0 or words[#words].br then
      words[#words + 1] = { piece }
    else
      table.insert(words[#words], piece)
    end
  end

  local indent = ctx.indent or ""
  local bullet = ctx.bullet
  local line_parts
  local line_width
  local prefix

  local function start_line()
    if bullet and not bullet.used then
      prefix = indent:sub(1, #indent - #bullet.pad) .. bullet.text
      bullet.used = true
    else
      prefix = indent
    end

    line_parts = {}
    line_width = display_width(prefix)
  end

  local function finish_line()
    local line = self:emit("")
    local content = prefix
    local col = #prefix

    if ctx.prefix_group and #prefix > 0 then
      self:highlight(line, 0, #prefix, ctx.prefix_group)
    elseif bullet and prefix ~= indent then
      self:highlight(line, #prefix - #bullet.text, #prefix, "OculusDevlogBullet")
    end

    for index, piece in ipairs(line_parts) do
      if index > 1 and piece.space then
        content = content .. " "
        col = col + 1
      end

      local start = col
      content = content .. piece.text
      col = col + #piece.text
      local run = piece.run

      if run.reference then
        self:highlight(line, start, col, "OculusDevlogReference")
        self:add_segment(run.reference, line, start, col)
      elseif run.href then
        self:highlight(line, start, col, "OculusDevlogLink")
      end

      if run.group then
        self:highlight(line, start, col, run.group)
      end

      if run.href then
        self:add_link(run.href, line, start, col)
      end
    end

    self.lines[line] = content
  end

  local available = math.max(10, self.width)
  start_line()

  for _, word in ipairs(words) do
    if word.br then
      finish_line()
      start_line()
    else
      local word_width = 0

      for _, piece in ipairs(word) do
        word_width = word_width + display_width(piece.text)
      end

      local gap = #line_parts > 0 and 1 or 0

      if #line_parts > 0 and line_width + gap + word_width > available then
        finish_line()
        start_line()
        gap = 0
      end

      for index, piece in ipairs(word) do
        line_parts[#line_parts + 1] = {
          text = piece.text,
          run = piece.run,
          space = index == 1 and #line_parts > 0,
        }
      end

      line_width = line_width + gap + word_width
    end
  end

  if #line_parts > 0 then
    finish_line()
  end
end

function Renderer:render_pre(node, ctx)
  self:flush(ctx)
  local text = table.concat(node_text(node)):gsub("\r\n?", "\n"):gsub("\t", "    ")
  local lines = vim.split(text, "\n", { plain = true })

  while lines[1] and vim.trim(lines[1]) == "" do
    table.remove(lines, 1)
  end

  while lines[#lines] and vim.trim(lines[#lines]) == "" do
    lines[#lines] = nil
  end

  if #lines == 0 then
    return
  end

  self.seen_content = true
  self.pending_blank = true
  self:blank_if_pending()
  local indent = (ctx.indent or "") .. "    "

  for _, text_line in ipairs(lines) do
    local line = self:emit(indent .. text_line)
    self:highlight(line, #indent, #indent + #text_line, "OculusDevlogCode")
  end

  self.pending_blank = true
end

function Renderer:walk_children(node, ctx)
  for _, child in ipairs(node.children or {}) do
    self:walk(child, ctx)
  end
end

function Renderer:walk(node, ctx)
  if node.text then
    self:push_run(node.text, ctx)
    return
  end

  local tag = node.tag

  if skipped_elements[tag] then
    return
  end

  if tag == "br" then
    self.runs[#self.runs + 1] = { br = true }
    return
  end

  if tag == "img" then
    local alt = collapse(node.attrs.alt or "")

    if alt ~= "" then
      self:push_run("[image: " .. alt .. "]", vim.tbl_extend("force", ctx, { group = "OculusDevlogMuted" }))
    end

    return
  end

  if tag == "pre" then
    self:render_pre(node, ctx)
    return
  end

  if tag == "hr" then
    self:flush(ctx)

    -- A rule before any text only separates the post from its title.
    if not self.seen_content then
      return
    end
    self.pending_blank = true
    self:blank_if_pending()
    local indent = ctx.indent or ""
    local rule = string.rep("─", math.max(3, math.min(self.width - display_width(indent), 40)))
    local line = self:emit(indent .. rule)
    self:highlight(line, #indent, #indent + #rule, "OculusDevlogMuted")
    self.pending_blank = true
    return
  end

  if tag == "a" then
    local href = M.resolve_url(node.attrs.href, self.base_url)

    -- Links within the page itself lead nowhere outside it, and a heading's
    -- link to itself ("#", "¶") is not part of its text.
    if href and self.base_url and href:gsub("#.*$", "") == self.base_url:gsub("#.*$", "") and href:find("#", 1, true) then
      local text = collapse(table.concat(node_text(node)))

      if text == "" or text == "#" or text == "¶" or text == "§" or text == "🔗" then
        return
      end

      href = nil
    end

    local reference = href and M.url_reference(href) or nil

    self:walk_children(node, vim.tbl_extend("force", ctx, {
      href = href or ctx.href,
      reference = reference or ctx.reference,
    }))

    return
  end

  if inline_groups[tag] then
    self:walk_children(node, vim.tbl_extend("force", ctx, {
      group = inline_groups[tag],
      code = inline_groups[tag] == "OculusDevlogCode" or ctx.code,
    }))

    return
  end

  if not block_elements[tag] and not heading_elements[tag] then
    self:walk_children(node, ctx)
    return
  end

  -- A block ends the paragraph before it.
  self:flush(ctx)

  if heading_elements[tag] then
    self.pending_blank = true
    local heading_ctx = vim.tbl_extend("force", ctx, { group = "OculusDevlogHeading", heading = true })
    self:walk_children(node, heading_ctx)
    self:flush(heading_ctx)
    self.pending_blank = true
    return
  end

  if tag == "ul" or tag == "ol" then
    local number = tonumber(node.attrs.start) or 1
    self.pending_blank = self.pending_blank or not ctx.in_list

    for _, child in ipairs(node.children) do
      if child.tag == "li" then
        local marker = tag == "ol" and (tostring(number) .. ". ") or "• "
        number = number + 1

        local item_ctx = vim.tbl_extend("force", ctx, {
          indent = (ctx.indent or "") .. string.rep(" ", display_width(marker)),
          bullet = { text = marker, pad = string.rep(" ", display_width(marker)), used = false },
          in_list = true,
          heading = false,
        })

        self:walk_children(child, item_ctx)
        self:flush(item_ctx)
      elseif child.tag then
        self:walk(child, ctx)
      end
    end

    if not ctx.in_list then
      self.pending_blank = true
    end

    return
  end

  if tag == "blockquote" then
    self.pending_blank = true
    local quote_ctx = vim.tbl_extend("force", ctx, {
      indent = (ctx.indent or "") .. "│ ",
      prefix_group = "OculusDevlogQuote",
      group = ctx.group or "OculusDevlogQuote",
      bullet = nil,
    })

    self:walk_children(node, quote_ctx)
    self:flush(quote_ctx)
    self.pending_blank = true
    return
  end

  if tag == "tr" then
    local first = true

    for _, cell in ipairs(node.children) do
      if cell.tag == "td" or cell.tag == "th" then
        if not first then
          self:push_run(" │ ", vim.tbl_extend("force", ctx, { group = "OculusDevlogMuted" }))
        end

        first = false

        self:walk_children(cell, vim.tbl_extend("force", ctx, {
          group = cell.tag == "th" and "OculusDevlogStrong" or ctx.group,
        }))
      end
    end

    self:flush(ctx)
    return
  end

  if tag == "dd" then
    local dd_ctx = vim.tbl_extend("force", ctx, { indent = (ctx.indent or "") .. "  " })
    self:walk_children(node, dd_ctx)
    self:flush(dd_ctx)
    return
  end

  if tag == "dt" then
    local dt_ctx = vim.tbl_extend("force", ctx, { group = "OculusDevlogStrong" })
    self:walk_children(node, dt_ctx)
    self:flush(dt_ctx)
    return
  end

  if tag == "figcaption" then
    local caption_ctx = vim.tbl_extend("force", ctx, { group = "OculusDevlogMuted" })
    self:walk_children(node, caption_ctx)
    self:flush(caption_ctx)
    return
  end

  if spaced_blocks[tag] then
    self.pending_blank = true
  end

  self:walk_children(node, ctx)
  self:flush(ctx)

  if spaced_blocks[tag] then
    self.pending_blank = true
  end
end

-- Render a post's HTML into lines no wider than opts.width, where possible.
-- Returns { lines, highlights = { {line, start, finish, group} }, links =
-- { {url, line, start, finish} }, references = { {label, url|target,
-- segments = { {line, start, finish} }} } }; lines are 1-based and columns
-- are 0-based byte offsets with an exclusive finish.
function M.render(html, opts)
  opts = opts or {}
  local tree = type(html) == "table" and html or M.parse_html(html or "")
  local renderer = new_renderer(opts)
  local content = opts.whole and tree or M.main_content(tree, opts.base_url)
  local ctx = { indent = "" }
  renderer:walk(content, ctx)
  renderer:flush(ctx)

  while renderer.lines[#renderer.lines] == "" do
    renderer.lines[#renderer.lines] = nil
  end

  return {
    lines = renderer.lines,
    highlights = renderer.highlights,
    links = renderer.links,
    references = renderer.references,
  }
end

local function fresh(entry, opts)
  return entry
    and not opts.force
    and os.time() - entry.fetched_at < (opts.cache_ttl or 300)
end

-- Pages -----------------------------------------------------------------------

-- What a changelog heading announces: a version ("v0.3.1", "[1.2.0] -
-- 2026-01-01", "Release 2.0") or a date.
local function release_heading(text)
  local bare = text:gsub("^[%[%(%s]+", "")

  if bare:match("^[vV]?%d+%.%d+")
    or bare:match("^[Vv]ersion%s+v?%d")
    or bare:match("^[Rr]elease%s+v?%d")
    or M.parse_date(text)
  then
    return true
  end

  return false
end

-- Read an HTML page that has no feed, such as a changelog, as a devlog: each
-- heading that names a release or a date starts a post, which runs to the
-- next such heading. Returns a feed like M.parse_feed, or nil.
function M.parse_page(html, page_url)
  local tree = M.parse_html(html)
  local content = M.main_content(tree)
  local by_level = {}

  local function collect(node)
    if node.tag and node.tag:match("^h[1-4]$") then
      if release_heading(collapse(table.concat(node_text(node)))) then
        by_level[node.tag] = by_level[node.tag] or {}
        table.insert(by_level[node.tag], node)
      end

      return
    end

    for _, child in ipairs(node.children or {}) do
      if child.tag then
        collect(child)
      end
    end
  end

  collect(content)

  -- Posts start at the heading level that names the most releases.
  local headings

  for _, level in ipairs({ "h1", "h2", "h3", "h4" }) do
    if by_level[level] and (not headings or #by_level[level] > #headings) then
      headings = by_level[level]
    end
  end

  if not headings then
    return nil
  end

  local starts = {}
  local holds = {}

  for _, heading in ipairs(headings) do
    starts[heading] = true
  end

  local function mark(node)
    local found = starts[node] == true

    for _, child in ipairs(node.children or {}) do
      if child.tag and mark(child) then
        found = true
      end
    end

    holds[node] = found
    return found
  end

  mark(content)

  -- Walk the page in order, handing each piece to the post it falls in. A
  -- piece that holds a post's heading is taken apart so the heading, and
  -- whatever sits beside it, go to the right post. Anything before the first
  -- heading introduces the page and is left out.
  local posts = {}
  local current

  local function place(node)
    if starts[node] then
      current = { heading = node, children = { node } }
      posts[#posts + 1] = current
    elseif holds[node] then
      local own = 0

      for _, child in ipairs(node.children) do
        if starts[child] then
          own = own + 1
        end
      end

      for _, child in ipairs(node.children) do
        -- A heading sharing a row with one release's heading, like a link to
        -- that release's documentation, belongs to the release's title rather
        -- than opening a section of it.
        if own == 1
          and node ~= content
          and not starts[child]
          and child.tag
          and child.tag:match("^h%d$")
        then
          child = { tag = "p", attrs = child.attrs, children = child.children }
        end

        place(child)
      end
    elseif current then
      current.children[#current.children + 1] = node
    end
  end

  place(content)

  local page = page_url:gsub("#.*$", "")
  local title_node = find_node(tree, function(node)
    return node.tag == "title"
  end)

  local feed = {
    title = title_node and collapse(table.concat(node_text({ children = title_node.children }))) or nil,
    link = page,
    page = true,
    posts = {},
  }

  for index, post in ipairs(posts) do
    local title = collapse(table.concat(node_text(post.heading)))
    local id = post.heading.attrs.id
    local url = id and id ~= "" and (page .. "#" .. id) or page
    local timestamp = M.parse_date(title)

    feed.posts[index] = {
      id = url ~= page and url or (page .. "#" .. index),
      title = title,
      url = url,
      timestamp = timestamp,
      date = timestamp and timestamp:sub(1, 10) or nil,
      -- The post is already a piece of the page, so it renders whole.
      content = { tag = "div", attrs = {}, children = post.children },
      whole = true,
      order = index,
    }
  end

  return feed
end

local release_cache = {}

local function version_key(text)
  local version = tostring(text or ""):gsub("^[%[%(%s]+", ""):match("^[vV]?(%d+%.%d+[%w.%-+]*)")
    or tostring(text or ""):match("[vV]?(%d+%.%d+[%w.%-+]*)")

  return version and version:lower() or nil
end

-- Give undated posts named after a version the date of the project's release
-- of that version. callback() runs once the posts that could be dated are.
function M.date_releases(feed, project, opts, callback)
  local undated = {}

  for _, post in ipairs(feed.posts or {}) do
    if not post.timestamp and version_key(post.title) then
      undated[#undated + 1] = post
    end
  end

  if #undated == 0 or type(project) ~= "table" or type(project.repository) ~= "string" then
    vim.schedule(callback)
    return
  end

  local function apply(releases)
    local dates = {}

    for _, release in ipairs(releases or {}) do
      for _, name in ipairs({ release.tag, release.name }) do
        local key = version_key(name)

        if key and release.published_at and not dates[key] then
          dates[key] = release.published_at
        end
      end
    end

    for _, post in ipairs(undated) do
      local published = dates[version_key(post.title)]
      local timestamp = published and M.parse_date(published)

      if timestamp then
        post.timestamp = timestamp
        post.date = timestamp:sub(1, 10)
      end
    end

    callback()
  end

  local key = M.project_key(project)
  local cached = release_cache[key]

  if fresh(cached, opts or {}) then
    vim.schedule(function()
      apply(cached.releases)
    end)

    return
  end

  local provider = project.provider == "codeberg"
      and require("oculus.codeberg")
    or require("oculus.github")

  provider.repository_releases(project.repository, opts or {}, function(releases)
    release_cache[key] = { fetched_at = os.time(), releases = releases or {} }
    apply(releases)
  end)
end

-- Fetching --------------------------------------------------------------------

-- Load and parse the feed at `url`: callback(feed, err, cached).
function M.fetch_feed(url, opts, callback)
  opts = opts or {}
  local cached = feed_cache[url]

  if fresh(cached, opts) then
    vim.schedule(function()
      callback(cached.feed, nil, true)
    end)

    return
  end

  request(url, opts, function(body, err)
    if not body then
      callback(nil, err)
      return
    end

    local feed, parse_err = M.parse_feed(body, url)

    -- Not a feed: read the page as a changelog, a post per release heading.
    if not feed and body:find("<[hH][1-6][%s>]") then
      feed = M.parse_page(body, url)
      parse_err = "found no releases or dated headings on the page"
    end

    if not feed then
      callback(nil, ("%s: %s"):format(M.display_url(url), parse_err))
      return
    end

    feed_cache[url] = { fetched_at = os.time(), feed = feed }
    callback(feed, nil, false)
  end)
end

-- The feed a homepage advertises with <link rel="alternate">, preferring a
-- blog, news or devlog feed and passing over comment feeds.
function M.advertised_feed(html, page_url)
  local best
  local best_score

  for tag in (html or ""):gmatch("<[lL][iI][nN][kK]%s[^>]*>") do
    local attrs = attributes(tag:sub(6, -2))
    local rel = " " .. (attrs.rel or ""):lower() .. " "
    local kind = (attrs.type or ""):lower()

    if rel:find(" alternate ", 1, true)
      and (kind:find("rss", 1, true) or kind:find("atom", 1, true))
      and attrs.href
    then
      local label = ((attrs.title or "") .. " " .. attrs.href):lower()
      local score = 0

      if label:find("comment", 1, true) then
        score = score - 10
      end

      if label:find("devlog", 1, true) or label:find("dev log", 1, true) then
        score = score + 6
      elseif label:find("blog", 1, true) or label:find("news", 1, true) then
        score = score + 3
      end

      if label:find("release", 1, true) then
        score = score - 1
      end

      if not best_score or score > best_score then
        best = M.resolve_url(attrs.href, page_url)
        best_score = score
      end
    end
  end

  return best
end

-- Probe the usual feed paths on `homepage` at once, taking the first path in
-- M.feed_paths order that serves a feed.
local function probe_feed_paths(homepage, opts, callback)
  local origin = homepage:match("^(%a[%w+.-]*://[^/?#]+)")

  if not origin then
    callback(nil)
    return
  end

  local results = {}
  local remaining = #M.feed_paths
  local timeout = math.min(tonumber(opts.request_timeout) or 15, 8)

  local function settle()
    for index = 1, #M.feed_paths do
      if results[index] == nil then
        return
      end

      if results[index] then
        callback(origin .. M.feed_paths[index])
        callback = function() end
        return
      end
    end

    callback(nil)
  end

  for index, path in ipairs(M.feed_paths) do
    request(origin .. path, opts, function(body)
      results[index] = type(body) == "string"
        and (body:find("<rss[%s>]") or body:find("<feed[%s>]")) ~= nil

      remaining = remaining - 1
      settle()
    end, timeout)
  end
end

-- Find a project's devlog feed. Returns through callback(url, source, err)
-- where source is "project", "setup", "saved" or "discovered".
function M.resolve_feed(project, opts, callback)
  opts = opts or {}
  local key = M.project_key(project)
  local repository = tostring(project.repository or ""):lower()

  if project.devlog == false then
    vim.schedule(function()
      callback(nil, nil, "the devlog is turned off for this project")
    end)

    return
  end

  if type(project.devlog) == "string" and project.devlog ~= "" then
    vim.schedule(function()
      callback(project.devlog, "project")
    end)

    return
  end

  local configured

  if type(opts.devlogs) == "table" then
    for _, name in ipairs({ key, repository, project.repository }) do
      if opts.devlogs[name] ~= nil then
        configured = opts.devlogs[name]
        break
      end
    end
  end

  if configured == false then
    vim.schedule(function()
      callback(nil, nil, "the devlog is turned off for this project")
    end)

    return
  end

  if type(configured) == "string" and configured ~= "" then
    vim.schedule(function()
      callback(configured, "setup")
    end)

    return
  end

  local saved = type(opts.devlog_feeds) == "table" and opts.devlog_feeds[key]

  if type(saved) == "table" and type(saved.url) == "string" and not opts.rediscover then
    vim.schedule(function()
      callback(saved.url, saved.discovered and "discovered" or "saved")
    end)

    return
  end

  local cached = discovery_cache[key]

  if fresh(cached, opts) then
    vim.schedule(function()
      callback(cached.url, cached.url and "discovered" or nil, cached.err)
    end)

    return
  end

  local provider = project.provider == "codeberg"
      and require("oculus.codeberg")
    or require("oculus.github")

  local function finish(url, err)
    discovery_cache[key] = { fetched_at = os.time(), url = url, err = err }
    callback(url, url and "discovered" or nil, err)
  end

  provider.repository_info(project.repository, opts, function(info, info_err)
    local homepage = info and info.homepage

    if type(homepage) ~= "string" or homepage == "" then
      finish(nil, info_err and tostring(info_err) or "the project has no homepage to find a devlog on")
      return
    end

    if not homepage:match("^%a[%w+.-]*://") then
      homepage = "https://" .. homepage
    end

    request(homepage, opts, function(html)
      local advertised = html and M.advertised_feed(html, homepage)

      if advertised then
        finish(advertised)
        return
      end

      probe_feed_paths(homepage, opts, function(url)
        finish(url, not url and ("no devlog feed found on " .. M.display_url(homepage)) or nil)
      end)
    end)
  end)
end

-- The HTML of a post: the feed's own copy when it carries the whole post,
-- otherwise the post's page. callback(html, base_url, err).
function M.post_html(post, opts, callback)
  opts = opts or {}

  if post.content and post.content ~= "" then
    vim.schedule(function()
      callback(post.content, post.url, nil, true)
    end)

    return
  end

  if not post.url then
    vim.schedule(function()
      callback(post.excerpt or "", nil, nil, true)
    end)

    return
  end

  local page_url = post.url:gsub("#.*$", "")
  local cached = page_cache[page_url]

  if fresh(cached, opts) then
    vim.schedule(function()
      callback(cached.html, post.url, nil, true)
    end)

    return
  end

  request(page_url, opts, function(html, err)
    if not html then
      -- Fall back to whatever the feed had.
      callback(post.excerpt or "", post.url, err, false)
      return
    end

    page_cache[page_url] = { fetched_at = os.time(), html = html }
    callback(html, post.url, nil, false)
  end)
end

function M.clear()
  release_cache = {}
  feed_cache = {}
  page_cache = {}
  discovery_cache = {}
end

return M
