local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local workspace = vim.fn.tempname()
assert(vim.fn.mkdir(workspace, "p") == 1)
local state_file = vim.fs.joinpath(workspace, "oculus.json")
vim.env.GITHUB_TOKEN = nil
vim.env.CODEBERG_TOKEN = nil
local devlog = require("oculus.devlog")
local browser = require("oculus.browser")
local inspect = require("oculus.inspect")
local window = require("oculus.window")

local function wait_for(label, predicate)
  assert(vim.wait(5000, predicate, 10), label)
end

-- Serves each curl request from `routes`, a map of URL to body (a string, or
-- a table sent as JSON); anything else is a 404. Requested URLs are recorded.
local requests = {}
local routes = {}
local original_system = vim.system

vim.system = function(command, _, on_exit)
  local url = command[#command]
  requests[#requests + 1] = { url = url, command = vim.deepcopy(command) }
  local body = routes[url]

  if type(body) == "table" then
    body = vim.json.encode(body)
  end

  on_exit({
    code = 0,
    stdout = (body or "Not Found") .. "\n" .. (body and "200" or "404"),
    stderr = "",
  })

  return {}
end

local function request_for(url)
  for index = #requests, 1, -1 do
    if requests[index].url == url then
      return requests[index].command
    end
  end

  return nil
end

local function has_argument(command, value)
  return command and vim.list_contains(command, value)
end

-- Entities and URLs.
do
  assert(devlog.decode_entities("a &amp; b &lt;c&gt; &#8217; &#x2014; &rsquo; &bogus;") == "a & b <c> ’ — ’ &bogus;")
  assert(devlog.resolve_url("/devlog/", "https://ziglang.org") == "https://ziglang.org/devlog/")
  assert(devlog.resolve_url("post.html", "https://a.org/blog/index.html") == "https://a.org/blog/post.html")
  assert(devlog.resolve_url("../x?y=1#z", "https://a.org/blog/2026/") == "https://a.org/blog/x?y=1#z")
  assert(devlog.resolve_url("#top", "https://a.org/p?q#old") == "https://a.org/p?q#top")
  assert(devlog.resolve_url("//cdn.org/f.xml", "https://a.org/") == "https://cdn.org/f.xml")
  assert(devlog.resolve_url("https://b.org/", "https://a.org/") == "https://b.org/")
  assert(devlog.parse_date("Thu, 27 Aug 2026 13:04:05 +0000") == "2026-08-27T13:04:05")
  assert(devlog.parse_date("2026-09-17T00:00:00Z") == "2026-09-17T00:00:00")
  assert(devlog.parse_date("2026-09-17") == "2026-09-17T00:00:00")
end

local zig_post = [[<div id="2026-08-27"><h1><a href="#2026-08-27">Pointer Stability</a></h1>
<p>Author: Robbie Lyman</p>
<p>Locks were <a href="https://github.com/ziglang/zig/pull/17719">added to the hash maps in 2024</a>,
and the follow-up in ziglang/zig#31000 fixed #30500 &amp; more. Not a reference: &#35;1 or a#123.</p>
<ul><li>First <code>#99999</code></li><li>See https://codeberg.org/ziglang/zig/issues/42.</li></ul>
<pre><code>const x = 1; // #12345
  indented</code></pre>
<p>Commit <a href="https://codeberg.org/ziglang/zig/commit/0123456789abcdef">0123456</a> and a
<a href="https://example.org/docs">plain link</a>.</p></div>]]

-- Pad the post past the length at which a description counts as the whole
-- post rather than an excerpt.
local zig_full = zig_post .. "<p>" .. string.rep("More words here. ", 70) .. "</p>"

local zig_feed = ([==[<rss version="2.0"><channel><title>Zig Devlog</title>
<link>https://ziglang.org/devlog/</link>
<item><title>Older Post</title><description>&lt;p&gt;Short.&lt;/p&gt;</description>
<link>https://ziglang.org/devlog/2026/#2026-06-30</link><pubDate>Tue, 30 Jun 2026 00:00:00 +0000</pubDate>
<guid>https://ziglang.org/devlog/2026/#2026-06-30</guid></item>
<item><title>Pointer Stability
</title><description><![CDATA[%s]]></description>
<link>https://ziglang.org/devlog/2026/#2026-08-27</link><pubDate>Thu, 27 Aug 2026 00:00:00 +0000</pubDate>
<guid>https://ziglang.org/devlog/2026/#2026-08-27</guid></item>
</channel></rss>]==]):format(zig_full)

-- Feeds: RSS posts sort newest first, carry a long description as the post,
-- and take a byline from the post when the feed names no author.
do
  local feed = assert(devlog.parse_feed(zig_feed, "https://ziglang.org/devlog/index.xml"))
  assert(feed.title == "Zig Devlog", feed.title)
  assert(feed.link == "https://ziglang.org/devlog/")
  assert(#feed.posts == 2)
  local post = feed.posts[1]
  assert(post.title == "Pointer Stability", post.title)
  assert(post.date == "2026-08-27")
  assert(post.author == "Robbie Lyman", tostring(post.author))
  assert(post.content and post.content:find("17719", 1, true))
  assert(feed.posts[2].content == nil, "a short description is an excerpt")

  local atom = assert(devlog.parse_feed([[<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>TB Blog</title>
<link href="https://tb.com/blog/atom.xml" rel="self"/><link href="https://tb.com/blog" rel="alternate"/>
<entry><id>tag:1</id><title>Hello</title><published>2026-09-17T00:00:00Z</published>
<link rel="alternate" href="/blog/hello"/><author><name>Tobi</name></author><author><name>Maxi</name></author>
<summary>An excerpt.</summary></entry></feed>]], "https://tb.com/blog/atom.xml"))

  assert(atom.link == "https://tb.com/blog")
  assert(atom.posts[1].url == "https://tb.com/blog/hello", atom.posts[1].url)
  assert(atom.posts[1].author == "Tobi, Maxi")
  assert(atom.posts[1].content == nil)
  assert(atom.posts[1].id == "tag:1")
  assert(not devlog.parse_feed("<html></html>", "https://x.org"))
end

-- Rendering finds references in links and prose, but not in code, and wraps
-- a link over several lines as one reference.
do
  local project = { repository = "ziglang/zig", provider = "codeberg" }

  local doc = devlog.render(zig_post, {
    width = 40,
    base_url = "https://ziglang.org/devlog/2026/#2026-08-27",
    project = project,
    projects = { project },
    skip_title = "Pointer Stability",
  })

  local text = table.concat(doc.lines, "\n")
  assert(not text:find("Pointer Stability", 1, true), "the title is shown once, in the header")
  assert(text:find("• First #99999", 1, true), text)
  assert(text:find("\n    const x = 1; // #12345\n      indented", 1, true), text)
  local labels = {}

  for _, reference in ipairs(doc.references) do
    labels[#labels + 1] = reference.label
  end

  assert(vim.deep_equal(labels, {
    "ziglang/zig#17719",
    "ziglang/zig#31000",
    "ziglang/zig#30500",
    "ziglang/zig#42",
    "ziglang/zig@0123456789",
  }), vim.inspect(labels))

  local pull = doc.references[1]
  assert(pull.url == "https://github.com/ziglang/zig/pull/17719")
  assert(#pull.segments == 2, "the link wraps onto a second line")

  for _, segment in ipairs(pull.segments) do
    local line = doc.lines[segment.line]
    assert(segment.finish <= #line)
  end

  local first = pull.segments[1]
  assert(doc.lines[first.line]:sub(first.start + 1, first.finish):find("^added"))
  local bare = doc.references[3]
  assert(bare.target == "ziglang/zig#30500" and not bare.url)
  assert(bare.web_url == "https://codeberg.org/ziglang/zig/issues/30500")
  assert(doc.references[4].url == "https://codeberg.org/ziglang/zig/issues/42")
  local plain = false

  for _, link in ipairs(doc.links) do
    plain = plain or link.url == "https://example.org/docs"
  end

  assert(plain, "plain links are kept for the browser")

  -- Pages: the article is the post, and scripts, navigation and the title
  -- repeated as a heading are left out.
  local page = devlog.render([[<html><head><title>X</title><style>p{color:#367533}</style></head>
<body><nav><a href="/">Home</a></nav><article><header><h1>Neovim 0.11</h1></header>
<h2>Highlights</h2><p>Fixes neovim/neovim#32000.</p><blockquote><p>Quoted</p></blockquote>
<script>var x = "#1234";</script></article><footer>Footer</footer></body></html>]], {
    width = 60,
    base_url = "https://neovim.io/news/2025/03/",
    project = { repository = "neovim/neovim" },
    skip_title = "Neovim 0.11",
  })

  assert(vim.deep_equal(page.lines, {
    "Highlights",
    "",
    "Fixes neovim/neovim#32000.",
    "",
    "│ Quoted",
  }), vim.inspect(page.lines))

  assert(#page.references == 1)

  -- The byline the header already shows, a heading's link to itself and an
  -- image with no description are left out.
  local trimmed = devlog.render([[<p>Author: Robbie Lyman</p><h2 id="a">Setup <a href="#a">#</a></h2>
<p><img src="banner.png"><img src="x.png" alt="A chart"> Text</p>]], {
    width = 60,
    base_url = "https://a.org/post",
    author = "Robbie Lyman",
  })

  assert(vim.deep_equal(trimmed.lines, { "Setup", "", "[image: A chart] Text" }), vim.inspect(trimmed.lines))

  -- A fragment picks out one post of a page holding several.
  local section = devlog.render([[<body><h2 id="one">One</h2><p>First</p><h2 id="two">Two</h2>
<p>Second</p><h3>Sub</h3><p>More</p><h2 id="three">Three</h2><p>Third</p></body>]], {
    width = 60,
    base_url = "https://a.org/log/#two",
  })

  assert(vim.deep_equal(section.lines, { "Two", "", "Second", "", "Sub", "", "More" }), vim.inspect(section.lines))
end

-- A page with no feed reads as a changelog: a post per release heading,
-- dated from the heading or from the project's release of that version.
do
  local page = [[<html><head><title>Changelog</title></head><body><nav>Menu</nav>
<div class="docs"><h1>Changelog</h1><p>Intro.</p>
<div style="display: flex"><h2 id="v0.3.1">v0.3.1</h2><h2><a href="/docs/v0.3.1/guide">Documentation</a></h2></div><hr>
<section><h2 id="bug-fixes">Bug Fixes</h2><ul><li>Fixed a crash, see #120.</li></ul></section>
<div style="display: flex"><h2 id="v0.3.0">v0.3.0</h2><h2><a href="/docs/v0.3.0/guide">Documentation</a></h2></div><hr>
<section><h2 id="new-features">New Features</h2><h3 id="bt">Bluetooth</h3><p>Added it.</p></section>
</div></body></html>]]

  routes["https://shell.org/changelog/"] = page

  routes["https://api.github.com/repos/owner/shell/releases?per_page=100"] = {
    { tag_name = "v0.3.1", published_at = "2026-08-21T02:37:12Z" },
    { tag_name = "v0.3.0", published_at = "2026-05-04T09:39:49Z" },
  }

  local feed

  devlog.fetch_feed("https://shell.org/changelog/", { force = true }, function(result, err)
    feed = assert(result, err)
  end)

  wait_for("the changelog page did not load", function()
    return feed ~= nil
  end)

  assert(feed.page and feed.title == "Changelog", vim.inspect(feed.title))
  assert(#feed.posts == 2, #feed.posts)
  assert(feed.posts[1].title == "v0.3.1" and feed.posts[1].url == "https://shell.org/changelog/#v0.3.1")
  assert(feed.posts[1].date == nil)
  local project = { repository = "owner/shell", provider = "github" }
  local dated = false

  devlog.date_releases(feed, project, {}, function()
    dated = true
  end)

  wait_for("the releases did not date the posts", function()
    return dated
  end)

  assert(feed.posts[1].date == "2026-08-21" and feed.posts[2].date == "2026-05-04")

  local doc = devlog.render(feed.posts[2].content, {
    width = 60,
    base_url = feed.posts[2].url,
    project = project,
    skip_title = feed.posts[2].title,
    whole = feed.posts[2].whole,
  })

  assert(vim.deep_equal(doc.lines, {
    "Documentation",
    "",
    "────────────────────────────────────────",
    "",
    "New Features",
    "",
    "Bluetooth",
    "",
    "Added it.",
  }), vim.inspect(doc.lines))

  assert(doc.highlights[1][4] == "OculusDevlogLink", "the documentation link is a link, not a heading")

  local first = devlog.render(feed.posts[1].content, {
    width = 60,
    base_url = feed.posts[1].url,
    project = project,
    skip_title = "v0.3.1",
    whole = true,
  })

  assert(first.references[1] and first.references[1].label == "owner/shell#120")

  -- Dates in the headings themselves, as in a keep-a-changelog file.
  local flat = assert(devlog.parse_page([[<body><main><h1>Changes</h1><h2>[Unreleased]</h2><p>Soon.</p>
<h2>[1.2.0] - 2026-01-05</h2><h3>Added</h3><p>A.</p><h2>Release 1.1.0 (March 3, 2025)</h2><p>B.</p></main></body>]],
    "https://x.org/CHANGELOG"))

  assert(#flat.posts == 2, #flat.posts)
  assert(flat.posts[1].title == "[1.2.0] - 2026-01-05" and flat.posts[1].date == "2026-01-05")
  assert(flat.posts[2].date == "2025-03-03", tostring(flat.posts[2].date))
  local flat_doc = devlog.render(flat.posts[1].content, { width = 60, skip_title = flat.posts[1].title, whole = true })
  assert(vim.deep_equal(flat_doc.lines, { "Added", "", "A." }), vim.inspect(flat_doc.lines))
  assert(not devlog.parse_page("<body><h2>About</h2><p>Nothing dated.</p></body>", "https://x.org/"))

  -- An index of articles, as on LWN's kernel page: each row pairs a date with
  -- a link, the largest list of rows wins, and each post is read from its link.
  local index = assert(devlog.parse_page([[<html><head><title>Kernel coverage</title></head><body><main>
<h3>The article index</h3><p>See <a href="/Kernel/Index/">the index</a>, updated September 1, 2026.</p>
<table><tr><td>September 22, 2026</td><td><a href="/Articles/1095553/">Compiling the kernel with gccrs</a></td></tr>
<tr><td>August 31, 2026</td><td><a href="/Articles/1089791/">The rest of the 7.3 merge window</a></td></tr></table>
<div class="AnnLine"><a href="/Articles/1096102/">A patch</a> <span>Sep 22</span></div></main></body></html>]],
    "https://lwn.net/Kernel/"))

  assert(index.title == "Kernel coverage")
  assert(#index.posts == 2, #index.posts)
  assert(index.posts[1].title == "Compiling the kernel with gccrs" and index.posts[1].date == "2026-09-22")
  assert(index.posts[2].url == "https://lwn.net/Articles/1089791/")
  assert(index.posts[2].content == nil, "the post is read from its own page")

  -- Mainline commits on git.kernel.org are torvalds/linux commits; ad boxes
  -- and a closing rule are left out.
  local article = devlog.render([[<div class="ArticleText"><main><blockquote class="ad"><b>Subscribe</b></blockquote>
<p>Merged: <a href="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=252d36716326">this commit</a>,
<a href="https://git.kernel.org/linus/30abb3a67f4b2aa160feeb3c0b771f730cbcca67">that one</a> and
<a href="https://git.kernel.org/pub/scm/linux/kernel/git/netdev/net-next.git/commit/?id=abcdef1234">a net-next one</a>.</p>
<hr></main></div>]], { width = 80, base_url = "https://lwn.net/Articles/1089791/" })

  assert(vim.deep_equal(article.lines, { "Merged: this commit, that one and a net-next one." }), vim.inspect(article.lines))
  assert(#article.references == 2, #article.references)
  assert(article.references[1].label == "torvalds/linux@252d367163")
  assert(article.references[1].url == "https://github.com/torvalds/linux/commit/252d36716326")
  assert(article.references[1].web_url:find("^https://git%.kernel%.org/pub/scm/"))
  assert(article.references[2].url == "https://github.com/torvalds/linux/commit/30abb3a67f4b2aa160feeb3c0b771f730cbcca67")
end

-- Subscriber cookies are sent only to HTTPS LWN pages, and switching to a
-- cookie file does not reuse an unauthenticated article from the cache.
do
  local article_url = "https://lwn.net/Articles/1095553/"
  local cookie_file = vim.fs.joinpath(workspace, "lwn-cookies.txt")
  local post = { url = article_url }
  routes[article_url] = "<p>Public preview.</p>"
  local html

  devlog.post_html(post, {}, function(body)
    html = body
  end)

  wait_for("the public LWN article did not load", function()
    return html ~= nil
  end)

  assert(html:find("Public preview", 1, true))
  assert(not has_argument(request_for(article_url), "--cookie"))
  assert(vim.fn.writefile({ "# Netscape HTTP Cookie File" }, cookie_file) == 0)
  routes[article_url] = "<p>Subscriber article.</p>"
  html = nil

  devlog.post_html(post, { lwn_cookie_file = cookie_file }, function(body)
    html = body
  end)

  wait_for("the subscriber LWN article did not load", function()
    return html ~= nil
  end)

  assert(html:find("Subscriber article", 1, true), html)
  assert(has_argument(request_for(article_url), "--cookie"))
  assert(has_argument(request_for(article_url), cookie_file))
  assert(has_argument(request_for(article_url), "=https"))
  local other_url = "https://elsewhere.org/feed.xml"
  routes[other_url] = "<rss><channel><title>Elsewhere</title></channel></rss>"
  local feed

  devlog.fetch_feed(other_url, { lwn_cookie_file = cookie_file }, function(result)
    feed = result
  end)

  wait_for("the other feed did not load", function()
    return feed ~= nil
  end)

  assert(not has_argument(request_for(other_url), "--cookie"))
  local before = #requests
  local error_message

  devlog.post_html(post, {
    force = true,
    lwn_cookie_file = cookie_file .. ".missing",
  }, function(_, _, err)
    error_message = err
  end)

  wait_for("the missing cookie file was not reported", function()
    return error_message ~= nil
  end)

  assert(error_message:find("cannot read the LWN cookie file", 1, true))
  assert(#requests == before, "curl must not treat a missing cookie file as a cookie string")
end

-- Discovery prefers a blog or devlog feed a homepage advertises.
do
  local html = [[<link rel="alternate" type="application/rss+xml" title="Comments Feed" href="/comments/feed/">
<link rel="alternate" type="application/rss+xml" title="Releases" href="/releases.xml">
<link href="/blog/feed.xml" rel="alternate" type="application/atom+xml" title="Blog">]]

  assert(devlog.advertised_feed(html, "https://a.org/") == "https://a.org/blog/feed.xml")
end

-- Feeds come from the project, then setup, then saved state, then the
-- project's homepage: its advertised feed, else the first common path.
do
  local function resolve(project, opts)
    local result

    devlog.resolve_feed(project, opts, function(url, source, err)
      result = { url = url, source = source, err = err }
    end)

    wait_for("the devlog feed did not resolve", function()
      return result ~= nil
    end)

    return result
  end

  local project = { repository = "owner/repo", provider = "github" }
  local result = resolve(vim.tbl_extend("force", project, { devlog = "https://p.org/feed" }), {})
  assert(result.url == "https://p.org/feed" and result.source == "project")
  result = resolve(vim.tbl_extend("force", project, { devlog = false }), {})
  assert(result.url == nil and result.err)
  result = resolve(project, { devlogs = { ["owner/repo"] = "https://s.org/feed" } })
  assert(result.url == "https://s.org/feed" and result.source == "setup")

  assert(vim.deep_equal(devlog.sources(project, { devlogs = {
    ["owner/repo"] = {
      { name = "Release notes", url = "https://s.org/feed" },
      { name = "Mailing list", url = "https://s.org/mail.atom" },
    },
  } }), {
    { name = "Release notes", url = "https://s.org/feed" },
    { name = "Mailing list", url = "https://s.org/mail.atom" },
  }))

  result = resolve(project, { devlog_feeds = { ["github:owner/repo"] = { url = "https://saved.org/feed" } } })
  assert(result.url == "https://saved.org/feed" and result.source == "saved")
  routes["https://api.github.com/repos/owner/repo"] = { name = "repo", homepage = "https://repo.dev" }
  routes["https://repo.dev"] = "<html><head></head></html>"
  routes["https://repo.dev/blog/atom.xml"] = "<feed></feed>"
  routes["https://repo.dev/rss.xml"] = "<rss></rss>"
  result = resolve(project, { force = true })
  assert(result.url == "https://repo.dev/blog/atom.xml" and result.source == "discovered", vim.inspect(result))
  routes["https://api.github.com/repos/owner/other"] = { name = "other" }
  result = resolve({ repository = "owner/other", provider = "github" }, { force = true })
  assert(result.url == nil and result.err:find("homepage", 1, true), vim.inspect(result))
  -- A user's blog: named on the entry, set up by "@login", or found from the
  -- website on their profile, following a link to the blog when the website
  -- has no feed of its own, but only to its own site or a blogging service.
  local writer = { username = "Writer", provider = "github" }
  result = resolve(vim.tbl_extend("force", writer, { blog = "https://w.org/feed" }), {})
  assert(result.url == "https://w.org/feed" and result.source == "project")
  result = resolve(writer, { devlogs = { ["@writer"] = "https://s.org/w.xml" } })
  assert(result.url == "https://s.org/w.xml" and result.source == "setup")
  assert(devlog.project_key(writer) == "github:@writer")
  routes["https://api.github.com/users/Writer"] = { login = "Writer", blog = "writer.dev" }
  routes["https://writer.dev"] = [[<a href="https://elsewhere.org/blog">Blog</a> <a href="/writing/">Writing</a>]]
  routes["https://writer.dev/writing/"] = [[<link rel="alternate" type="application/atom+xml" href="/writing/atom.xml">]]
  result = resolve(writer, { force = true })
  assert(result.url == "https://writer.dev/writing/atom.xml" and result.source == "discovered", vim.inspect(result))
  routes["https://api.github.com/users/Moved"] = { login = "Moved", blog = "https://moved.io" }
  routes["https://moved.io"] = [[<a href="https://github.blog">Blog</a> <a href="https://world.hey.com/moved">HEY World</a>]]
  routes["https://world.hey.com/moved"] = [[<link rel="alternate" type="application/atom+xml" href="https://world.hey.com/moved/feed.atom">]]
  result = resolve({ username = "Moved", provider = "github" }, { force = true })
  assert(result.url == "https://world.hey.com/moved/feed.atom", vim.inspect(result))
  routes["https://api.github.com/users/Quiet"] = { login = "Quiet" }
  result = resolve({ username = "Quiet", provider = "github" }, { force = true })
  assert(result.url == nil and result.err:find("website", 1, true), vim.inspect(result))
end

-- The window: L opens a project's devlog, a post opens in the reader, and a
-- reference in it is inspected.
local opened_urls = {}
local inspected = {}

browser.open = function(url)
  opened_urls[#opened_urls + 1] = url
  return true
end

inspect.open = function(url, _, _, lifecycle)
  inspected[#inspected + 1] = { url = url }
  lifecycle.on_progress("⠋")
  return true
end

inspect.inspect_by_id = function(target, _, context, _, lifecycle)
  inspected[#inspected + 1] = { target = target, project = context.project }
  lifecycle.on_complete(nil)
  return true
end

local function press(lhs)
  local mapping = vim.fn.maparg(lhs, "n", false, true)
  assert(mapping.callback, "no mapping for " .. lhs)
  mapping.callback()
end

local zig = {
  repository = "ziglang/zig",
  provider = "codeberg",
  name = "Zig",
  devlog = "https://ziglang.org/devlog/index.xml",
}

routes["https://ziglang.org/devlog/index.xml"] = zig_feed
routes["https://ziglang.org/devlog/2026/"] = "<html><body><div id=\"2026-06-30\"><p>The older post, from its page.</p></div></body></html>"
vim.o.columns = 160
vim.o.lines = 50

window.open({
  navigation = { up = "i", down = "k", left = "j", right = "l", inspect = "h", inspect_id = "H" },
  width = 0.8,
  height = 0.8,
  border = "rounded",
  state_file = state_file,
  gh_token_fallback = false,
  projects = { zig },
  contributors = {},
})

local state = window.state

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf or state.buf, 0, -1, false), "\n")
end

local function footer_text(current)
  return table.concat(vim.api.nvim_buf_get_lines(current.footer_buf, 0, -1, false), "\n")
end

assert(window.state.line_targets[vim.api.nvim_win_get_cursor(state.win)[1]].kind == "project")
press("d")

wait_for("the devlog did not load", function()
  return state.view == "devlog" and state.project_devlog and not state.project_devlog.loading
end)

local text = buffer_text()
assert(text:find("DEVLOG", 1, true))
assert(text:find("ziglang/zig · Zig Devlog", 1, true), text)
assert(text:find("2026-08-27  Pointer Stability", 1, true))
assert(text:find("2026-06-30  Older Post", 1, true))
assert(state.selected_devlog_post == "https://ziglang.org/devlog/2026/#2026-08-27")
-- The preview names the post without quoting it.
local preview = {}

for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.buf, -1, 0, -1, { details = true })) do
  local chunks = mark[4].virt_text

  if chunks and chunks[2] and chunks[2][1]:match("%S") then
    preview[#preview + 1] = vim.trim(chunks[2][1])
  end
end

assert(vim.deep_equal(preview, {
  "POST",
  "Pointer Stability",
  "2026-08-27 · Robbie Lyman",
  "ziglang.org/devlog/2026/#2026-08-27",
}), vim.inspect(preview))

press("k")
assert(state.selected_devlog_post == "https://ziglang.org/devlog/2026/#2026-06-30")
press("b")
assert(opened_urls[#opened_urls] == "https://ziglang.org/devlog/2026/#2026-06-30")
-- A post whose feed entry is an excerpt is read from its page.
press("<CR>")
local reader = state.devlog_reader
assert(reader and vim.api.nvim_get_current_win() == reader.win)

wait_for("the page post did not load", function()
  return reader.doc ~= nil
end)

assert(buffer_text(reader.buf):find("The older post, from its page.", 1, true))
assert(window.state.win and vim.api.nvim_win_is_valid(window.state.win), "the reader keeps Oculus open")
press("q")
assert(state.devlog_reader == nil and not vim.api.nvim_win_is_valid(reader.win))
assert(vim.api.nvim_get_current_win() == state.win)
press("i")
assert(state.selected_devlog_post == "https://ziglang.org/devlog/2026/#2026-08-27")
press("l")
reader = state.devlog_reader

wait_for("the post did not load", function()
  return reader.doc ~= nil
end)

text = buffer_text(reader.buf)
assert(text:find("  Pointer Stability\n  2026-08-27 · Robbie Lyman · ziglang/zig devlog", 1, true), text)
assert(vim.api.nvim_win_is_valid(reader.footer_win))
assert(footer_text(reader):find("5 activity references", 1, true), footer_text(reader))
-- Tab walks the references; the footer names the one under the cursor.
press("<Tab>")
assert(footer_text(reader):find("ziglang/zig#17719", 1, true), footer_text(reader))
local line = vim.api.nvim_get_current_line()
assert(line:sub(vim.api.nvim_win_get_cursor(reader.win)[2] + 1):find("^added"), line)
press("h")
assert(inspected[1].url == "https://github.com/ziglang/zig/pull/17719")
assert(footer_text(reader):find("inspecting ziglang/zig#17719", 1, true), footer_text(reader))
reader.inspecting = nil
press("<Tab>")
press("<Tab>")
press("<CR>")
assert(inspected[2].target == "ziglang/zig#30500", vim.inspect(inspected[2]))
assert(inspected[2].project == zig)
press("b")
assert(opened_urls[#opened_urls] == "https://codeberg.org/ziglang/zig/issues/30500")
press("<S-Tab>")
assert(footer_text(reader):find("ziglang/zig#31000", 1, true), footer_text(reader))
-- After the post, each reference is listed once, and Tab goes on to the
-- list and then wraps back to the first reference in the post.
text = buffer_text(reader.buf)
assert(text:find("\n  REFERENCED ACTIVITY %(5%)\n\n  ziglang/zig#17719  pull request · added to the hash maps in 2024\n"), text)
assert(text:find("\n  ziglang/zig#30500  issue or pull request\n", 1, true), text)
assert(text:find("\n  ziglang/zig@0123456789  commit\n", 1, true), text)
press("<Tab>")
press("<Tab>")
press("<Tab>")
assert(footer_text(reader):find("ziglang/zig@0123456789", 1, true), footer_text(reader))
press("<Tab>")
assert(footer_text(reader):find("ziglang/zig#17719", 1, true), footer_text(reader))
assert(vim.api.nvim_win_get_cursor(reader.win)[1] == reader.section_start, "the list entry, not the post")
press("<Tab>")
press("<Tab>")
assert(vim.api.nvim_get_current_line():find("^  ziglang/zig#30500"), vim.api.nvim_get_current_line())
press("h")
assert(inspected[#inspected].target == "ziglang/zig#30500", vim.inspect(inspected[#inspected]))
press("<Tab>")
press("<Tab>")
assert(vim.api.nvim_get_current_line():find("^  ziglang/zig@0123456789"))
press("<Tab>")
assert(vim.api.nvim_win_get_cursor(reader.win)[1] < reader.section_start, "Tab wraps to the post")
assert(footer_text(reader):find("ziglang/zig#17719", 1, true), footer_text(reader))
press("<S-Tab>")
assert(vim.api.nvim_get_current_line():find("^  ziglang/zig@0123456789"), "S-Tab wraps to the list")
-- Closing Oculus, as inspecting does, remembers the post, and reopening
-- returns to it.
local cursor = vim.api.nvim_win_get_cursor(reader.win)
window.close()
assert(not vim.api.nvim_win_is_valid(reader.win) and not vim.api.nvim_win_is_valid(reader.footer_win))
assert(state.devlog_resume and state.devlog_resume.post.title == "Pointer Stability")
window.open(window.state.opts)
reader = state.devlog_reader
assert(reader and reader.post.title == "Pointer Stability")

wait_for("the resumed post did not load", function()
  return reader.doc ~= nil
end)

assert(vim.deep_equal(vim.api.nvim_win_get_cursor(reader.win), cursor))
-- Opening another view over a remembered post closes the post.
window.close()
assert(window.open_project("github:owner/nolog-yet", window.state.opts))
assert(state.devlog_reader == nil and not vim.api.nvim_win_is_valid(reader.win))
assert(state.view == "activity", state.view)
window.close()
state.view = "devlog"
window.open(window.state.opts)
assert(state.view == "devlog" and state.devlog_reader == nil, "the replaced post is not reopened")
press("l")
reader = state.devlog_reader
assert(reader and reader.post.title == "Pointer Stability")
-- Back out of the reader, then out of the devlog to the project list.
press("j")
assert(state.view == "devlog" and state.devlog_reader == nil)
press("j")
assert(state.view == "contributors", state.view)

-- d on a user reads their blog: "#123" means nothing without a project, and
-- back returns to the users.
routes["https://writer.dev/writing/atom.xml"] = [[<feed><title>Writing</title><entry><id>w1</id><title>On tools</title>
<updated>2026-09-01T00:00:00Z</updated><link href="https://writer.dev/writing/tools"/>
<content type="html">&lt;p&gt;Fixed #1234 and neovim/neovim#5678. ]] .. string.rep("Words. ", 200) .. [[&lt;/p&gt;</content></entry></feed>]]

local writer = { username = "Writer", provider = "github" }
window.state.opts.contributors = { writer }
window.state.contributors = { writer }
press("u")
assert(state.community_view == "users", state.community_view)
assert(state.line_targets[vim.api.nvim_win_get_cursor(state.win)[1]].username == "Writer")
press("d")

wait_for("the blog did not load", function()
  return state.view == "devlog" and state.project_devlog.project == writer and not state.project_devlog.loading
end)

text = buffer_text()
assert(text:find("  BLOG\n  @Writer · Writing\n"), text)
press("<CR>")
reader = state.devlog_reader

wait_for("the blog post did not load", function()
  return reader.doc ~= nil
end)

text = buffer_text(reader.buf)
assert(text:find("  On tools\n  2026-09-01 · @Writer blog\n", 1, true), text)
assert(#reader.doc.references == 1 and reader.doc.references[1].label == "neovim/neovim#5678")
press("q")
press("j")
assert(state.view == "contributors" and state.community_view == "users", state.view)
press("p")
-- A project with no devlog to be found offers to set a feed URL, which is
-- saved and used.
routes["https://api.github.com/repos/owner/nolog"] = { name = "nolog" }
local nolog = { repository = "owner/nolog", provider = "github" }
window.state.opts.projects[#window.state.opts.projects + 1] = nolog
assert(window.open_devlog("owner/nolog", window.state.opts))

wait_for("the missing devlog did not settle", function()
  return state.project_devlog and state.project_devlog.project.repository == "owner/nolog"
    and not state.project_devlog.loading
end)

assert(buffer_text():find("No devlog found for this project.", 1, true), buffer_text())
local original_input = vim.ui.input

vim.ui.input = function(_, on_confirm)
  on_confirm("https://nolog.dev/feed.xml")
end

routes["https://nolog.dev/feed.xml"] = [[<rss><channel><title>No Log</title>
<item><title>First</title><link>https://nolog.dev/1</link><description>Hi</description></item></channel></rss>]]

press("e")
vim.ui.input = original_input

wait_for("the set feed did not load", function()
  return not state.project_devlog.loading and state.project_devlog.posts
end)

assert(buffer_text():find("First", 1, true))
assert(window.state.opts.devlog_feeds["github:owner/nolog"].url == "https://nolog.dev/feed.xml")
local saved = require("oculus.storage").load(state_file)
assert(saved.devlog_feeds["github:owner/nolog"].url == "https://nolog.dev/feed.xml")

-- A project with two named devlogs opens a source list. Each source has its
-- own posts and reader, and back returns through the source list.
local linux = {
  repository = "torvalds/linux",
  provider = "github",
  name = "linux",
  devlog = {
    { name = "LWN kernel coverage", url = "https://lwn.net/Kernel/" },
    { name = "Linux kernel mailing list", url = "https://lore.kernel.org/lkml/new.atom" },
  },
}

window.state.opts.projects[#window.state.opts.projects + 1] = linux

routes["https://lwn.net/Kernel/"] = [[<html><head><title>Kernel coverage</title></head><body><main>
<table><tr><td>September 22, 2026</td><td><a href="/Articles/1099999/">Kernel article</a></td></tr>
<tr><td>September 21, 2026</td><td><a href="/Articles/1095552/">Earlier article</a></td></tr></table>
</main></body></html>]]

routes["https://lwn.net/Articles/1099999/"] = "<main><p>LWN article body.</p></main>"

routes["https://lore.kernel.org/lkml/new.atom"] = [[<feed xmlns="http://www.w3.org/2005/Atom">
<title>linux-kernel.vger.kernel.org archive mirror</title><entry><author><name>Kernel Writer</name></author>
<title>LKML message</title><updated>2026-09-23T22:12:38Z</updated>
<link href="https://lore.kernel.org/lkml/message@example.org/"/>
<content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><pre>Hi &lt;reader&gt;,
The kernel mailing list body.</pre></div></content></entry></feed>]]

assert(window.open_devlog("torvalds/linux", window.state.opts))
assert(state.project_devlog.selecting_source)
assert(buffer_text():find("LWN kernel coverage", 1, true))
assert(buffer_text():find("Linux kernel mailing list", 1, true))
press("<CR>")

wait_for("the LWN source did not load", function()
  return not state.project_devlog.loading and not state.project_devlog.selecting_source
end)

assert(state.project_devlog.posts[1].title == "Kernel article")
press("<CR>")
reader = state.devlog_reader

wait_for("the LWN article did not load", function()
  return reader.doc ~= nil
end)

assert(buffer_text(reader.buf):find("LWN article body.", 1, true))
press("q")
press("j")
assert(state.project_devlog.selecting_source)
press("k")
assert(state.project_devlog.selected_source == 2)
press("<CR>")

wait_for("the LKML source did not load", function()
  return not state.project_devlog.loading and state.project_devlog.source_index == 2
end)

assert(state.project_devlog.posts[1].title == "LKML message")
press("<CR>")
reader = state.devlog_reader

wait_for("the LKML message did not load", function()
  return reader.doc ~= nil
end)

assert(buffer_text(reader.buf):find("Hi <reader>", 1, true))
assert(buffer_text(reader.buf):find("The kernel mailing list body.", 1, true))
press("q")
press("j")
assert(state.project_devlog.selecting_source)
press("j")
assert(state.view == "contributors")
window.close()
vim.system = original_system
print("devlog spec ok")
