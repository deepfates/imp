# The one CSV dialect Imp reads and writes: RFC 4180 with CRLF line endings.
# Reading accepts CRLF, LF and a bare CR as line breaks and drops a leading
# byte order mark; writing quotes any field holding a comma, a quote, a line
# feed or a carriage return, so what Imp writes it reads back unchanged.
NimbleCSV.define(Imp.CSV,
  separator: ",",
  escape: "\"",
  line_separator: "\r\n",
  newlines: ["\r\n", "\n", "\r"],
  reserved: ["\"", ",", "\n", "\r"],
  trim_bom: true,
  moduledoc: false
)
