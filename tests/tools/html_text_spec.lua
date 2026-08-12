-- HTML → markdown for w:web_fetch (weave.tools.html_text): keep the prose,
-- the structure and the link targets; drop the chrome.

local Html = require("weave.tools.html_text")

describe("tools.html_text", function()
  it("drops script/style/svg/comments with their contents", function()
    local out = Html.to_markdown([[
      <html><head><style>body { color: red }</style></head>
      <body><script>alert("no")</script><!-- hidden -->
      <p>kept</p><svg><path d="M0"/></svg></body></html>
    ]])
    assert.equal("kept", out)
  end)

  it("keeps headings, lists and paragraphs as markdown", function()
    local out = Html.to_markdown("<h2>Install</h2><p>Run this:</p><ul><li>one</li><li>two</li></ul>")
    assert.equal("## Install\n\nRun this:\n\n- one\n- two", out)
  end)

  it("keeps a link's target, since that is the next fetch", function()
    assert.equal(
      "see [the docs](https://example.com/docs)",
      Html.to_markdown('<p>see <a class="x" href="https://example.com/docs">the docs</a></p>')
    )
    -- an in-page anchor is not a destination worth carrying
    assert.equal("top", Html.to_markdown('<a href="#top">top</a>'))
  end)

  it("fences <pre> and backticks inline <code>", function()
    assert.equal("```\nlocal x = 1\n```", Html.to_markdown("<pre><code>local x = 1</code></pre>"))
    assert.equal("call `require()` first", Html.to_markdown("<p>call <code>require()</code> first</p>"))
  end)

  it("marks emphasis and rules", function()
    assert.equal("**bold** and *thin*", Html.to_markdown("<p><strong>bold</strong> and <em>thin</em></p>"))
    assert.equal("a\n\n---\n\nb", Html.to_markdown("<p>a</p><hr/><p>b</p>"))
  end)

  it("decodes entities, named and numeric", function()
    assert.equal("a & b < c > d “q” ©", Html.to_markdown("<p>a &amp; b &lt; c &gt; d &ldquo;q&rdquo; &#169;</p>"))
  end)

  it("collapses the whitespace HTML never meant", function()
    assert.equal("one two\n\nthree", Html.to_markdown("<p>one    \n\t  two</p>\n\n\n\n<p>three</p>"))
  end)

  it("takes the title from the original document", function()
    assert.equal("Weave — docs", Html.title("<html><head><title>Weave &mdash;\n  docs</title></head></html>"))
    assert.is_nil(Html.title("<html><body>no title</body></html>"))
  end)

  it("survives markup it cannot make sense of", function()
    local out = Html.to_markdown("<p>unclosed <b>bold <i>and italic")
    assert.truthy(out:find("unclosed", 1, true))
    assert.is_nil(out:find("<", 1, true))
  end)
end)
