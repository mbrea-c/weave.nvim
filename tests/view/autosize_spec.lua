-- Auto-resizing input boxes (prompt box, comment editor): the box follows its
-- content between 3 and 8 content rows, borders excluded. height() answers in
-- border-box terms (content rows + 2), matching text_input's height prop.

local Autosize = require("weave.view.autosize")

describe("view.autosize", function()
  it("floors empty/short text at the 3-row minimum", function()
    assert.equal(5, Autosize.height(""))
    assert.equal(5, Autosize.height(nil))
    assert.equal(5, Autosize.height("one\ntwo"))
  end)

  it("grows one row per line", function()
    assert.equal(6, Autosize.height("1\n2\n3\n4"))
    assert.equal(9, Autosize.height("1\n2\n3\n4\n5\n6\n7"))
  end)

  it("caps at 8 content rows", function()
    assert.equal(10, Autosize.height(("x\n"):rep(7) .. "x"))
    assert.equal(10, Autosize.height(("x\n"):rep(30)))
  end)

  it("honours a taller configured floor, which also lifts the cap", function()
    assert.equal(8, Autosize.height("", 6))
    assert.equal(12, Autosize.height(("x\n"):rep(30), 10))
  end)

  it("never sinks below the minimum on a smaller floor", function()
    assert.equal(5, Autosize.height("", 1))
  end)
end)
