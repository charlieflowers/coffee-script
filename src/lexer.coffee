# The CoffeeScript Lexer. Uses a series of token-matching regexes to attempt
# matches against the beginning of the source code. When a match is found,
# a token is produced, we consume the match, and start again. Tokens are in the
# form:
#
#     [tag, value, locationData]
#
# where locationData is {first_line, first_column, last_line, last_column}, which is a
# format that can be fed directly into [Jison](http://github.com/zaach/jison).  These
# are read by jison in the `parser.lexer` function defined in coffee-script.coffee.

{Rewriter, INVERSES} = require './rewriter'

# Import the helpers we need.
{count, starts, compact, last, repeat, invertLiterate,
locationDataToString,  throwSyntaxError} = require './helpers'

# The Lexer Class
# ---------------

# The Lexer class reads a stream of CoffeeScript and divvies it up into tagged
# tokens. Some potential ambiguity in the grammar has been avoided by
# pushing some extra smarts into the Lexer.
exports.Lexer = class Lexer

  # **tokenize** is the Lexer's main method. Scan by attempting to match tokens
  # one at a time, using a regular expression anchored at the start of the
  # remaining code, or a custom recursive token-matching method
  # (for interpolations). When the next token has been recorded, we move forward
  # within the code past the token, and begin again.
  #
  # Each tokenizing method is responsible for returning the number of characters
  # it has consumed.
  #
  # Before returning the token stream, run it through the [Rewriter](rewriter.html)
  # unless explicitly asked not to.
  tokenize: (code, opts = {}) ->
    @literate   = opts.literate  # Are we lexing literate CoffeeScript?
    @indent     = 0              # The current indentation level.
    @baseIndent = 0              # The overall minimum indentation level
    @indebt     = 0              # The over-indentation at the current level.
    @outdebt    = 0              # The under-outdentation at the current level.
    @indents    = []             # The stack of all current indentation levels.
    @ends       = []             # The stack for pairing up tokens.
    @tokens     = []             # Stream of parsed tokens in the form `['TYPE', value, location data]`.

    @chunkLine =
      opts.line or 0         # The start line for the current @chunk.
    @chunkColumn =
      opts.column or 0       # The start column of the current @chunk.
    code = @clean code         # The stripped, cleaned original source code.

    # At every position, run through this list of attempted matches,
    # short-circuiting if any of them succeed. Their order determines precedence:
    # `@literalToken` is the fallback catch-all.
    i = 0
    while @chunk = code[i..]
      consumed = \
           @identifierToken() or
           @commentToken()    or
           @whitespaceToken() or
           @lineToken()       or
           @heredocToken()    or
           @stringToken()     or
           @numberToken()     or
           @regexToken()      or
           @jsToken()         or
           @literalToken()

      # Update position
      [@chunkLine, @chunkColumn] = @getLineAndColumnFromChunk consumed

      i += consumed

    @closeIndentation()
    @error "missing #{tag}" if tag = @ends.pop()
    return @tokens if opts.rewrite is off
    (new Rewriter).rewrite @tokens

  # Preprocess the code to remove leading and trailing whitespace, carriage
  # returns, etc. If we're lexing literate CoffeeScript, strip external Markdown
  # by removing all lines that aren't indented by at least four spaces or a tab.
  clean: (code) ->
    code = code.slice(1) if code.charCodeAt(0) is BOM
    code = code.replace(/\r/g, '').replace TRAILING_SPACES, ''
    if WHITESPACE.test code
      code = "\n#{code}"
      @chunkLine--
    code = invertLiterate code if @literate
    code

  # Tokenizers
  # ----------

  # Matches identifying literals: variables, keywords, method names, etc.
  # Check to ensure that JavaScript reserved words aren't being used as
  # identifiers. Because CoffeeScript reserves a handful of keywords that are
  # allowed in JavaScript, we're careful not to tag them as keywords when
  # referenced as property names here, so you can still do `jQuery.is()` even
  # though `is` means `===` otherwise.
  identifierToken: ->
    return 0 unless match = IDENTIFIER.exec @chunk
    [input, id, colon] = match

    # Preserve length of id for location data
    idLength = id.length
    poppedToken = undefined

    # This if handles "for own key, value of myObject", loop over keys and values of obj, ignoring proptotype
    # If previous token's tag was 'FOR' and this is 'OWN', then make a token called 'OWN'
    if id is 'own' and @tag() is 'FOR'
      @token 'OWN', id
      return id.length

    # colon will be truthy if the identifier ended in a single colon, which is
    # how you define object members in object literal (json) format.
    # In that case, we set "forcedIdentifier" to true. It means, "damn it, this is an identifier, I'm sure of it."
    # But forcedIdentifier can ALSO be true if the previous token was ".", "?.", :: or ?::
    # OR, it can be true if the previos token was NOT SPACED and it is "@". All that makes sense.
    forcedIdentifier = colon or
      (prev = last @tokens) and (prev[0] in ['.', '?.', '::', '?::'] or
      not prev.spaced and prev[0] is '@') # if the previous token was "@" and there is no space between(?)
    tag = 'IDENTIFIER'

    # only do this if it is nOT forcedIdentifier. See if the identifier is in JS_KEYWORDS or COFFEE_KEYWORDS
    if not forcedIdentifier and (id in JS_KEYWORDS or id in COFFEE_KEYWORDS)
      tag = id.toUpperCase()
      # if we're using WHEN, and the previous tag was LINE_BREAK, then this is a LEADING_WHEN token.
      if tag is 'WHEN' and @tag() in LINE_BREAK
        tag = 'LEADING_WHEN'
      else if tag is 'FOR' # just make a note we've seen FOR. in a CLASS VAR, so it outlives this stack frame.
        @seenFor = yes
      else if tag is 'UNLESS' # UNLESS is turned into an IF token
        tag = 'IF'
      else if tag in UNARY # meaning, tag is "~" or "!
        tag = 'UNARY'
      else if tag in RELATION # meaning, IN, OF, or INSTANCEOF
        if tag isnt 'INSTANCEOF' and @seenFor
          # tag could be "FORIN" or "FOROF" ()
          # but note, @seenFor is a CLASS variable. So we're REMEMBERING that context across many tokens. So, FOR ... IN and FOR ... OF
          # Yech, i hate the way that's handled.
          tag = 'FOR' + tag
          @seenFor = no
        else
          # here, it could be IN, OF, or INSTANCEOF, and @seenFor was not true.
          tag = 'RELATION' # so all uses of IN, OF and INSTANCEOF outside of FOR are considered RELATIONS.
          # @value() is another function for peeking at the previous token, but it gets the VALUE of that token. So it the value
          # was "!", pop that token off! Change our ID to "!IN", "!FOR" or "!INSTANCEOF" (note, that's our VALUE, not our TAG)
          # so he is merely consolidating the 2 tags into one.
          if @value() is '!'
            poppedToken = @tokens.pop()
            id = '!' + id

    # if id is one of the js or cs reserved words (and a few others), but forcedIndentifier is true, label it an an identifier.
    # otherwise, if it is RESERVED, error out.
    if id in JS_FORBIDDEN
      if forcedIdentifier
        tag = 'IDENTIFIER'
        id  = new String id
        id.reserved = yes
      else if id in RESERVED
        # you can get here if forcedIdentifier is NOT TRUE, and the id is in RESERVED.
        @error "reserved word \"#{id}\""
        # if forcedIdentifier is FALSE, and the id IS in JS_FORBIDDEN, but NOT in RESERVED, you'll keep going. Those possibilities
        # are: JS_KEYWORDS and STRICT_PROSCRIBED, so things like "true, false, typeof" or "eval, arguments"

    # continuing with the case above, if you are using one of the reserved words, and forcedIdentifier is false, go inside this block
    # but also, of course, if you're not even using a reserved work and forcedIdentifier is false.
    unless forcedIdentifier
      # change id to the coffee alias (resolve the coffee alias) if it is one of those
      id  = COFFEE_ALIAS_MAP[id] if id in COFFEE_ALIASES
      # handle these cases here because they were created by alias resolution!
      tag = switch id
        when '!'                 then 'UNARY'
        when '==', '!='          then 'COMPARE'
        when '&&', '||'          then 'LOGIC'
        when 'true', 'false'     then 'BOOL'
        when 'break', 'continue' then 'STATEMENT'
        else  tag

    # now, we make a token using the tag we have chosen.
    tagToken = @token tag, id, 0, idLength
    if poppedToken
      # if he previously consolidated 2 tokens, lets correct the location data to encompass the span of both of them
      [tagToken[2].first_line, tagToken[2].first_column] =
        [poppedToken[2].first_line, poppedToken[2].first_column]
    if colon
      colonOffset = input.lastIndexOf ':'
      @token ':', ':', colonOffset, colon.length # The colon token is a *separate* token! ok, but it fucks up my mental model.

    # As always, we return the length
    input.length

  # Matches numbers, including decimals, hex, and exponential notation.
  # Be careful not to interfere with ranges-in-progress.
  numberToken: ->
    return 0 unless match = NUMBER.exec @chunk
    number = match[0]
    if /^0[BOX]/.test number
      @error "radix prefix '#{number}' must be lowercase"
    else if /E/.test(number) and not /^0x/.test number
      @error "exponential notation '#{number}' must be indicated with a lowercase 'e'"
    else if /^0\d*[89]/.test number
      @error "decimal literal '#{number}' must not be prefixed with '0'"
    else if /^0\d+/.test number
      @error "octal literal '#{number}' must be prefixed with '0o'"
    lexedLength = number.length
    if octalLiteral = /^0o([0-7]+)/.exec number
      number = '0x' + parseInt(octalLiteral[1], 8).toString 16
    if binaryLiteral = /^0b([01]+)/.exec number
      number = '0x' + parseInt(binaryLiteral[1], 2).toString 16
    @token 'NUMBER', number, 0, lexedLength
    lexedLength

  # Matches strings, including multi-line strings. Ensures that quotation marks
  # are balanced within the string's contents, and within nested interpolations.
  stringToken: ->
    switch quote = @chunk.charAt 0
      # when 1st char is single quote, match SIMPLESTR.
      # The [string] = syntax uses destructuring. It means, expect the rhs to be an
      # array of 1 item, and set string to that one item. If the regex match returns
      # undefined, then default to an empty array, meaning string will be undefined.
      when "'" then [string] = SIMPLESTR.exec(@chunk) || []
      # when the first char is double quotes, call @balancedString on the chunk,
      # passing in a double quote.
      #
      # The interesting thing here is that he supports strings within interpolated strings within interpolated strings, ad infinitum, as long as things are balanced. I need to see an example of that.
      #
      when '"' then string = @balancedString @chunk, '"'
    return 0 unless string
    trimmed = @removeNewlines string[1...-1]
    if quote is '"' and 0 < string.indexOf '#{', 1
      @interpolateString trimmed, strOffset: 1, lexedLength: string.length
    else
      @token 'STRING', quote + @escapeLines(trimmed) + quote, 0, string.length
    if octalEsc = /^(?:\\.|[^\\])*\\(?:0[0-7]|[1-7])/.test string
      @error "octal escape sequences #{string} are not allowed"
    string.length

  # Matches heredocs, adjusting indentation to the correct level, as heredocs
  # preserve whitespace, but ignore indentation to the left.
  heredocToken: ->
    return 0 unless match = HEREDOC.exec @chunk
    heredoc = match[0]
    quote = heredoc.charAt 0
    doc = @sanitizeHeredoc match[2], quote: quote, indent: null
    if quote is '"' and 0 <= doc.indexOf '#{'
      @interpolateString doc, heredoc: yes, strOffset: 3, lexedLength: heredoc.length
    else
      @token 'STRING', @makeString(doc, quote, yes), 0, heredoc.length
    heredoc.length

  # Matches and consumes comments.
  commentToken: ->
    return 0 unless match = @chunk.match COMMENT
    [comment, here] = match
    if here
      @token 'HERECOMMENT',
        (@sanitizeHeredoc here,
          herecomment: true, indent: repeat ' ', @indent),
        0, comment.length
    comment.length

  # Matches JavaScript interpolated directly into the source via backticks.
  jsToken: ->
    return 0 unless @chunk.charAt(0) is '`' and match = JSTOKEN.exec @chunk
    @token 'JS', (script = match[0])[1...-1], 0, script.length
    script.length

  # Matches regular expression literals. Lexing regular expressions is difficult
  # to distinguish from division, so we borrow some basic heuristics from
  # JavaScript and Ruby.
  regexToken: ->
    return 0 if @chunk.charAt(0) isnt '/'
    return length if length = @heregexToken()

    prev = last @tokens
    return 0 if prev and (prev[0] in (if prev.spaced then NOT_REGEX else NOT_SPACED_REGEX))
    return 0 unless match = REGEX.exec @chunk
    [match, regex, flags] = match
    # Avoid conflicts with floor division operator.
    return 0 if regex is '//'
    if regex[..1] is '/*' then @error 'regular expressions cannot begin with `*`'
    @token 'REGEX', "#{regex}#{flags}", 0, match.length
    match.length

  # Matches multiline extended regular expressions.
  heregexToken: ->
    return 0 unless match = HEREGEX.exec @chunk
    [heregex, body, flags] = match
    if 0 > body.indexOf '#{'
      re = @escapeLines body.replace(HEREGEX_OMIT, '$1$2').replace(/\//g, '\\/'), yes
      if re.match /^\*/ then @error 'regular expressions cannot begin with `*`'
      @token 'REGEX', "/#{ re or '(?:)' }/#{flags}", 0, heregex.length
      return heregex.length
    @token 'IDENTIFIER', 'RegExp', 0, 0
    @token 'CALL_START', '(', 0, 0
    tokens = []
    for token in @interpolateString(body, regex: yes)
      [tag, value] = token
      if tag is 'TOKENS'
        tokens.push value...
      else if tag is 'NEOSTRING'
        continue unless value = value.replace HEREGEX_OMIT, '$1$2'
        # Convert NEOSTRING into STRING
        value = value.replace /\\/g, '\\\\'
        token[0] = 'STRING'
        token[1] = @makeString(value, '"', yes)
        tokens.push token
      else
        @error "Unexpected #{tag}"

      prev = last @tokens
      plusToken = ['+', '+']
      plusToken[2] = prev[2] # Copy location data
      tokens.push plusToken

    # Remove the extra "+"
    tokens.pop()

    unless tokens[0]?[0] is 'STRING'
      @token 'STRING', '""', 0, 0
      @token '+', '+', 0, 0
    @tokens.push tokens...

    if flags
      # Find the flags in the heregex
      flagsOffset = heregex.lastIndexOf flags
      @token ',', ',', flagsOffset, 0
      @token 'STRING', '"' + flags + '"', flagsOffset, flags.length

    @token ')', ')', heregex.length-1, 0
    heregex.length

  # Matches newlines, indents, and outdents, and determines which is which.
  # If we can detect that the current line is continued onto the the next line,
  # then the newline is suppressed:
  #
  #     elements
  #       .each( ... )
  #       .map( ... )
  #
  # Keeps track of the level of indentation, because a single outdent token
  # can close multiple indents, so we need to know how far in we happen to be.
  lineToken: ->
    # if the next token is not \n, then return 0
    return 0 unless match = MULTI_DENT.exec @chunk
    # the regex captures at least one of "newline plus trailing whitespace stopping at nonwhitespace or next newline."
    # so: /n <space> <tab> <space> /n /n <space> /n /n would ALL be matched. And match[0] would contain that entire string. (match[0] is all this fn uses).
    #
    indent = match[0] # now indent = the full matched text
    @seenFor = no
    size = indent.length - 1 - indent.lastIndexOf '\n' # size, for my example, would be 9 - 1 - 8 = zero! And that makes sense, because I DID do some indenting in there, but
    #  that indenting was "covered up" by subsequent newlines that did not re-state that indenting. You could treat it as indent if you wanted, but it would be followed immediately
    #  by enough OUTDENTS to cancel it out. So makes sense to ignore them. Just get the amount of whitespace I put after the LAST newline.

    # now, consider the case of: \n <space> <tab> <space> \n \n <space> \n \n <space> <tab> (I added <space> and <tab> to end of previous example)
    # size would now be 11 - 1 - 8 = 2, which is due to the 2 whitespace charas i have on the end!

    noNewlines = @unfinished() # certain expressions are ended by newline (such as comments). If we're in one of these, noNewLines will now be true.

    # why would the amount of TRAILING WHITESPACE *AFTER* a newline be relevant or important? Well, DUH! If it is AFTER a newline, then it is ON THE NEXT LINE!!!!
    # So this whitespace is whitespace AT THE START OF A NEW LINE.
  #
  # So what are these class variables?
  # 1) @indent: Set to zero at the entry point, it is labelled as "the current indent level"
  # 2) @indebt: Set to 0 at entry, it is labelled as "the overindentation at the current point". But WTF does that mean?
    if size - @indebt is @indent
      console.log "Branch 1: size - @indebt is @indent, indentation was kept same"
      # @token 'HERECOMMENT', 'HERECOMMENT', 0, 0
      # WARNING!!! "@indent" is NOT THE SAME AS "indent"!!!
      # WARNING!!! "@indebt" is different too!

      # So, if the amount of whitespace on the new line minus @indebt == @indent, then we are going to make a token
      # The normal case is that token will be a newlineToken(0). But if we're inside one of those "unfinished" expressions, it will be @suppressNewLines.
      # @newlineToken is a fn that usually makes a TERMINATOR token. But it won't if the last token is ALREADY a TERMINATOR. And it pops off all the ";" tokens first.
      #
      # BUT: if noNewLines is true (which means we're in one of those "unfinished" expressions), then DON'T call newlineToken and DON'T make a TERMINATOR.
      # Instead, call suppressNewlines, which says, if the last token was a \, then just consume that \, and don't create a newline token. The \ means the coder wants to
      # suppress a newline. If the last token was not \, we won't pop a token, and we won't make a TERMINATOR token either. So it is as if there was no newline there.
      # I suspect these "unfinished" tokens are things that are allowed to span many lines. Let's see ... //, LOGIC, +, etc.
      if noNewlines
        console.log "Branch 1.1: noNewLines is true, so suppressNewLines"
        @suppressNewlines()
      else
        console.log "Branch 1.2: newNoewLines is false, so add a newlineToken (aka TERMINATOR)
        @newlineToken 0
        return indent.length

    console.log "Branch 2: indentation is not kept same"

    # Next case: if the new indentation is > the current indent level, then we have indented further.
    if size > @indent
      console.log "Branch 3: size of new indent is > previous indent, we've indented further"
      if noNewlines
        console.log "Branch 3.1: noNewLines is true, so suppressNewLines"
        # if this is one of those unfinished expressions, change the INDEBT to the amount that the new whitespace exceeds the current indent level
        @indebt = size - @indent
        # then, suppressNewlines and return
        @suppressNewlines()
        return indent.length

      # but if we're NOT in one of those unfinished expressions, then ...
      # if there are no tokens lexed yet, set the baseIndent and indent to the amount of whitespace found.
      console.log "Branch 3.2: noNewLines is false"
      unless @tokens.length
        console.log "Branch 3.3: there are not any tokens yet, so set base indent and don't return any token"
        @baseIndent = @indent = size
        # And don't return any token.
        return indent.length

      console.log "Branch 3.4: there are some tokens already, so make an INDENT token"
      diff = size - @indent + @outdebt # ugh!! Next step is to see what @outdebt is. But it has become clear to me that I will do multiple passes, and my FIRST pass will be WHAT'S REALLY IN THE FILE!
        # shit. outdebt is defined as the "underoutdentation of the current line". What in the holy fuck does that mean?
      @token 'INDENT', diff, indent.length - size, size
      @indents.push diff
      @ends.push 'OUTDENT'
      @outdebt = @indebt = 0
      @indent = size
    else if size < @baseIndent
      console.log "Branch 4: size is not greater than @indent, and size is < @baseIndent. This is ERROR, missing identation"
      @error 'missing indentation', indent.length
    else
      console.log "Branch 5: size is not > @indent, and size is not < @baseIndent. Make an OUTDENT token"
      # understanding this branch. size <= @indent, meaning we have outdented. But we did not outdent too far to make error, so create outdent
      @indebt = 0
      @outdentToken @indent - size, noNewlines, indent.length
    indent.length

  # Record an outdent token or multiple tokens, if we happen to be moving back
  # inwards past several recorded indents. Sets new @indent value.
  outdentToken: (moveOut, noNewlines, outdentLength) ->
    decreasedIndent = @indent - moveOut
    while moveOut > 0
      lastIndent = @indents[@indents.length - 1]
      if not lastIndent
        moveOut = 0
      else if lastIndent is @outdebt
        moveOut -= @outdebt
        @outdebt = 0
      else if lastIndent < @outdebt
        @outdebt -= lastIndent
        moveOut  -= lastIndent
      else
        dent = @indents.pop() + @outdebt
        if outdentLength and @chunk[outdentLength] in INDENTABLE_CLOSERS
          decreasedIndent -= dent - moveOut
          moveOut = dent
        @outdebt = 0
        # pair might call outdentToken, so preserve decreasedIndent
        @pair 'OUTDENT'
        @token 'OUTDENT', moveOut, 0, outdentLength
        moveOut -= dent
    @outdebt -= moveOut if dent
    @tokens.pop() while @value() is ';'

    @token 'TERMINATOR', '\n', outdentLength, 0 unless @tag() is 'TERMINATOR' or noNewlines
    @indent = decreasedIndent
    this

  # Matches and consumes non-meaningful whitespace. Tag the previous token
  # as being "spaced", because there are some cases where it makes a difference.
  whitespaceToken: ->
    return 0 unless (match = WHITESPACE.exec @chunk) or
                    (nline = @chunk.charAt(0) is '\n')
    prev = last @tokens
    prev[if match then 'spaced' else 'newLine'] = true if prev
    if match then match[0].length else 0

  # Generate a newline token. Consecutive newlines get merged together.
  # crf newlineToken: While the last token in the token array is ";", pop. So, remove all the semicolon tokens at the end of the token array.
  # If the previously paresed tag was TERMINATOR, do NOTHING! Otherwise, create a TERMINATOR token whose value is \n at the offset passed in
  #  and a length of 0.
  newlineToken: (offset) ->
    @tokens.pop() while @value() is ';'
    @token 'TERMINATOR', '\n', offset, 0 unless @tag() is 'TERMINATOR'
    this

  # Use a `\` at a line-ending to suppress the newline.
  # The slash is removed here once its job is done.
  suppressNewlines: ->
    @tokens.pop() if @value() is '\\'
    this

  # We treat all other single characters as a token. E.g.: `( ) , . !`
  # Multi-character operators are also literal tokens, so that Jison can assign
  # the proper order of operations. There are some symbols that we tag specially
  # here. `;` and newlines are both treated as a `TERMINATOR`, we distinguish
  # parentheses that indicate a method call from regular parentheses, and so on.
  literalToken: ->
    if match = OPERATOR.exec @chunk
      [value] = match
      @tagParameters() if CODE.test value
    else
      value = @chunk.charAt 0
    tag  = value
    prev = last @tokens
    if value is '=' and prev
      if not prev[1].reserved and prev[1] in JS_FORBIDDEN
        @error "reserved word \"#{@value()}\" can't be assigned"
      if prev[1] in ['||', '&&']
        prev[0] = 'COMPOUND_ASSIGN'
        prev[1] += '='
        return value.length
    if value is ';'
      @seenFor = no
      tag = 'TERMINATOR'
    else if value in MATH            then tag = 'MATH'
    else if value in COMPARE         then tag = 'COMPARE'
    else if value in COMPOUND_ASSIGN then tag = 'COMPOUND_ASSIGN'
    else if value in UNARY           then tag = 'UNARY'
    else if value in UNARY_MATH      then tag = 'UNARY_MATH'
    else if value in SHIFT           then tag = 'SHIFT'
    else if value in LOGIC or value is '?' and prev?.spaced then tag = 'LOGIC'
    else if prev and not prev.spaced
      if value is '(' and prev[0] in CALLABLE
        prev[0] = 'FUNC_EXIST' if prev[0] is '?'
        tag = 'CALL_START'
      else if value is '[' and prev[0] in INDEXABLE
        tag = 'INDEX_START'
        switch prev[0]
          when '?'  then prev[0] = 'INDEX_SOAK'
    switch value
      when '(', '{', '[' then @ends.push INVERSES[value]
      when ')', '}', ']' then @pair value
    @token tag, value
    value.length

  # Token Manipulators
  # ------------------

  # Sanitize a heredoc or herecomment by
  # erasing all external indentation on the left-hand side.
  sanitizeHeredoc: (doc, options) ->
    {indent, herecomment} = options
    if herecomment
      if HEREDOC_ILLEGAL.test doc
        @error "block comment cannot contain \"*/\", starting"
      return doc if doc.indexOf('\n') < 0
    else
      while match = HEREDOC_INDENT.exec doc
        attempt = match[1]
        indent = attempt if indent is null or 0 < attempt.length < indent.length
    doc = doc.replace /// \n #{indent} ///g, '\n' if indent
    doc = doc.replace /^\n/, '' unless herecomment
    doc

  # A source of ambiguity in our grammar used to be parameter lists in function
  # definitions versus argument lists in function calls. Walk backwards, tagging
  # parameters specially in order to make things easier for the parser.
  tagParameters: ->
    return this if @tag() isnt ')'
    stack = []
    {tokens} = this
    i = tokens.length
    tokens[--i][0] = 'PARAM_END'
    while tok = tokens[--i]
      switch tok[0]
        when ')'
          stack.push tok
        when '(', 'CALL_START'
          if stack.length then stack.pop()
          else if tok[0] is '('
            tok[0] = 'PARAM_START'
            return this
          else return this
    this

  # Close up all remaining open blocks at the end of the file.
  closeIndentation: ->
    @outdentToken @indent

  # Matches a balanced group such as a single or double-quoted string. Pass in
  # a series of delimiters, all of which must be nested correctly within the
  # contents of the string. This method allows us to have strings within
  # interpolations within strings, ad infinitum.
  #
  # crf balancedString
  balancedString: (str, end) ->
    continueCount = 0
    stack = [end]
    for i in [1...str.length]
      if continueCount
        --continueCount
        continue
      switch letter = str.charAt i
        when '\\'
          ++continueCount
          continue
        when end
          stack.pop()
          unless stack.length
            return str[0..i]
          end = stack[stack.length - 1]
          continue
      if end is '}' and letter in ['"', "'"]
        stack.push end = letter
      else if end is '}' and letter is '/' and match = (HEREGEX.exec(str[i..]) or REGEX.exec(str[i..]))
        continueCount += match[0].length - 1
      else if end is '}' and letter is '{'
        stack.push end = '}'
      else if end is '"' and prev is '#' and letter is '{'
        stack.push end = '}'
      prev = letter
    @error "missing #{ stack.pop() }, starting"

  # Expand variables and expressions inside double-quoted strings using
  # Ruby-like notation for substitution of arbitrary expressions.
  #
  #     "Hello #{name.capitalize()}."
  #
  # If it encounters an interpolation, this method will recursively create a
  # new Lexer, tokenize the interpolated contents, and merge them into the
  # token stream.
  #
  #  - `str` is the start of the string contents (IE with the " or """ stripped
  #    off.)
  #  - `options.offsetInChunk` is the start of the interpolated string in the
  #    current chunk, including the " or """, etc...  If not provided, this is
  #    assumed to be 0.  `options.lexedLength` is the length of the
  #    interpolated string, including both the start and end quotes.  Both of these
  #    values are ignored if `options.regex` is true.
  #  - `options.strOffset` is the offset of str, relative to the start of the
  #    current chunk.
  interpolateString: (str, options = {}) ->
    {heredoc, regex, offsetInChunk, strOffset, lexedLength} = options
    offsetInChunk ||= 0
    strOffset ||= 0
    lexedLength ||= str.length

    # Parse the string.
    tokens = []
    pi = 0
    i  = -1
    while letter = str.charAt i += 1
      if letter is '\\'
        i += 1
        continue
      unless letter is '#' and str.charAt(i+1) is '{' and
             (expr = @balancedString str[i + 1..], '}')
        continue
      # NEOSTRING is a fake token.  This will be converted to a string below.
      tokens.push @makeToken('NEOSTRING', str[pi...i], strOffset + pi) if pi < i
      unless errorToken
        errorToken = @makeToken '', 'string interpolation', offsetInChunk + i + 1, 2
      inner = expr[1...-1]
      if inner.length
        [line, column] = @getLineAndColumnFromChunk(strOffset + i + 1)
        nested = new Lexer().tokenize inner, line: line, column: column, rewrite: off
        popped = nested.pop()
        popped = nested.shift() if nested[0]?[0] is 'TERMINATOR'
        if len = nested.length
          if len > 1
            nested.unshift @makeToken '(', '(', strOffset + i + 1, 0
            nested.push    @makeToken ')', ')', strOffset + i + 1 + inner.length, 0
          # Push a fake 'TOKENS' token, which will get turned into real tokens below.
          tokens.push ['TOKENS', nested]
      i += expr.length
      pi = i + 1
    tokens.push @makeToken('NEOSTRING', str[pi..], strOffset + pi) if i > pi < str.length

    # If regex, then return now and let the regex code deal with all these fake tokens
    return tokens if regex

    # If we didn't find any tokens, then just return an empty string.
    return @token 'STRING', '""', offsetInChunk, lexedLength unless tokens.length

    # If the first token is not a string, add a fake empty string to the beginning.
    tokens.unshift @makeToken('NEOSTRING', '', offsetInChunk) unless tokens[0][0] is 'NEOSTRING'

    if interpolated = tokens.length > 1
      @token '(', '(', offsetInChunk, 0, errorToken

    # Push all the tokens
    for token, i in tokens
      [tag, value] = token
      if i
        # Create a 0-length "+" token.
        plusToken = @token '+', '+' if i
        locationToken = if tag == 'TOKENS' then value[0] else token
        plusToken[2] =
          first_line: locationToken[2].first_line
          first_column: locationToken[2].first_column
          last_line: locationToken[2].first_line
          last_column: locationToken[2].first_column
      if tag is 'TOKENS'
        # Push all the tokens in the fake 'TOKENS' token.  These already have
        # sane location data.
        @tokens.push value...
      else if tag is 'NEOSTRING'
        # Convert NEOSTRING into STRING
        token[0] = 'STRING'
        token[1] = @makeString value, '"', heredoc
        @tokens.push token
      else
        @error "Unexpected #{tag}"
    if interpolated
      rparen = @makeToken ')', ')', offsetInChunk + lexedLength, 0
      rparen.stringEnd = true
      @tokens.push rparen
    tokens

  # Pairs up a closing token, ensuring that all listed pairs of tokens are
  # correctly balanced throughout the course of the token stream.
  pair: (tag) ->
    unless tag is wanted = last @ends
      @error "unmatched #{tag}" unless 'OUTDENT' is wanted
      # Auto-close INDENT to support syntax like this:
      #
      #     el.click((event) ->
      #       el.hide())
      #
      @outdentToken last(@indents), true
      return @pair tag
    @ends.pop()

  # Helpers
  # -------

  # Returns the line and column number from an offset into the current chunk.
  #
  # `offset` is a number of characters into @chunk.
  getLineAndColumnFromChunk: (offset) ->
    if offset is 0
      return [@chunkLine, @chunkColumn]

    if offset >= @chunk.length
      string = @chunk
    else
      string = @chunk[..offset-1]

    lineCount = count string, '\n'

    column = @chunkColumn
    if lineCount > 0
      lines = string.split '\n'
      column = last(lines).length
    else
      column += string.length

    [@chunkLine + lineCount, column]

  # Same as "token", exception this just returns the token without adding it
  # to the results.
  makeToken: (tag, value, offsetInChunk = 0, length = value.length) ->
    locationData = {}
    [locationData.first_line, locationData.first_column] =
      @getLineAndColumnFromChunk offsetInChunk

    # Use length - 1 for the final offset - we're supplying the last_line and the last_column,
    # so if last_column == first_column, then we're looking at a character of length 1.
    lastCharacter = Math.max 0, length - 1
    [locationData.last_line, locationData.last_column] =
      @getLineAndColumnFromChunk offsetInChunk + lastCharacter

    token = [tag, value, locationData]

    token

  # Add a token to the results.
  # `offset` is the offset into the current @chunk where the token starts.
  # `length` is the length of the token in the @chunk, after the offset.  If
  # not specified, the length of `value` will be used.
  #
  # Returns the new token.
  # crf token
  token: (tag, value, offsetInChunk, length, origin) ->
    token = @makeToken tag, value, offsetInChunk, length
    token.origin = origin if origin
    @tokens.push token
    token

  # crf tag:
  # Find the last token that was parsed (unless you pass an index), and either return its TAG field, or set its TAG field.
  # Peek at a tag in the current token stream.
  tag: (index, tag) ->
    (tok = last @tokens, index) and if tag then tok[0] = tag else tok[0]

  # crf value
  # This is a helper that is usually called as a getter, but can also be called as a "setter". To call it as a getter, call with no args, as in foo = @value();
  # It will call "last" on the tokens array. "last" is the 4th helper from helpers.coffee. It gets the tail element of the array.
  # # So, as a getter, this gets the last token from the tokens array and returns its tok[1]. tok[1] is the "value" field of the token (a token is [tag, value, locationData])
  # as a "setter", it changes the "value" field of the last token.
  # Peek at a value in the current token stream.
  value: (index, val) ->
    (tok = last @tokens, index) and if val then tok[1] = val else tok[1]

  # Are we in the midst of an unfinished expression?
  unfinished: ->
    LINE_CONTINUER.test(@chunk) or
    @tag() in ['\\', '.', '?.', '?::', 'UNARY', 'MATH', 'UNARY_MATH', '+', '-',
               '**', 'SHIFT', 'RELATION', 'COMPARE', 'LOGIC', 'THROW', 'EXTENDS']

  # Remove newlines from beginning and (non escaped) from end of string literals.
  removeNewlines: (str) ->
    str.replace(/^\s*\n\s*/, '')
       .replace(/([^\\]|\\\\)\s*\n\s*$/, '$1')

  # Converts newlines for string literals.
  escapeLines: (str, heredoc) ->
    # Ignore escaped backslashes and remove escaped newlines
    str = str.replace /\\[^\S\n]*(\n|\\)\s*/g, (escaped, character) ->
      if character is '\n' then '' else escaped
    if heredoc
      str.replace MULTILINER, '\\n'
    else
      str.replace /\s*\n\s*/g, ' '

  # Constructs a string token by escaping quotes and newlines.
  makeString: (body, quote, heredoc) ->
    return quote + quote unless body
    # Ignore escaped backslashes and unescape quotes
    body = body.replace /// \\( #{quote} | \\ ) ///g, (match, contents) ->
      if contents is quote then contents else match
    body = body.replace /// #{quote} ///g, '\\$&'
    quote + @escapeLines(body, heredoc) + quote

  # Throws a compiler error on the current position.
  error: (message, offset = 0) ->
    # TODO: Are there some cases we could improve the error line number by
    # passing the offset in the chunk where the error happened?
    [first_line, first_column] = @getLineAndColumnFromChunk offset
    throwSyntaxError message, {first_line, first_column}

# Constants
# ---------

# Keywords that CoffeeScript shares in common with JavaScript.
JS_KEYWORDS = [
  'true', 'false', 'null', 'this'
  'new', 'delete', 'typeof', 'in', 'instanceof'
  'return', 'throw', 'break', 'continue', 'debugger'
  'if', 'else', 'switch', 'for', 'while', 'do', 'try', 'catch', 'finally'
  'class', 'extends', 'super'
]

# CoffeeScript-only keywords.
COFFEE_KEYWORDS = ['undefined', 'then', 'unless', 'until', 'loop', 'of', 'by', 'when']

COFFEE_ALIAS_MAP =
  and  : '&&'
  or   : '||'
  is   : '=='
  isnt : '!='
  not  : '!'
  yes  : 'true'
  no   : 'false'
  on   : 'true'
  off  : 'false'

COFFEE_ALIASES  = (key for key of COFFEE_ALIAS_MAP)
COFFEE_KEYWORDS = COFFEE_KEYWORDS.concat COFFEE_ALIASES

# The list of keywords that are reserved by JavaScript, but not used, or are
# used by CoffeeScript internally. We throw an error when these are encountered,
# to avoid having a JavaScript error at runtime.
RESERVED = [
  'case', 'default', 'function', 'var', 'void', 'with', 'const', 'let', 'enum'
  'export', 'import', 'native', '__hasProp', '__extends', '__slice', '__bind'
  '__indexOf', 'implements', 'interface', 'package', 'private', 'protected'
  'public', 'static', 'yield'
]

STRICT_PROSCRIBED = ['arguments', 'eval']

# The superset of both JavaScript keywords and reserved words, none of which may
# be used as identifiers or properties.
JS_FORBIDDEN = JS_KEYWORDS.concat(RESERVED).concat(STRICT_PROSCRIBED)

exports.RESERVED = RESERVED.concat(JS_KEYWORDS).concat(COFFEE_KEYWORDS).concat(STRICT_PROSCRIBED)
exports.STRICT_PROSCRIBED = STRICT_PROSCRIBED

# The character code of the nasty Microsoft madness otherwise known as the BOM.
BOM = 65279

# Token matching regexes.
IDENTIFIER = /// ^
  ( [$A-Za-z_\x7f-\uffff][$\w\x7f-\uffff]* )
  ( [^\n\S]* : (?!:) )?  # Is this a property name?
///

NUMBER     = ///
  ^ 0b[01]+    |              # binary
  ^ 0o[0-7]+   |              # octal
  ^ 0x[\da-f]+ |              # hex
  ^ \d*\.?\d+ (?:e[+-]?\d+)?  # decimal
///i

HEREDOC    = /// ^ ("""|''') ((?: \\[\s\S] | [^\\] )*?) (?:\n[^\n\S]*)? \1 ///

OPERATOR   = /// ^ (
  ?: [-=]>             # function
   | [-+*/%<>&|^!?=]=  # compound assign / compare
   | >>>=?             # zero-fill right shift
   | ([-+:])\1         # doubles
   | ([&|<>*/%])\2=?   # logic / shift / power / floor division / modulo
   | \?(\.|::)         # soak access
   | \.{2,3}           # range or splat
) ///

WHITESPACE = /^[^\n\S]+/

COMMENT    = /^###([^#][\s\S]*?)(?:###[^\n\S]*|###$)|^(?:\s*#(?!##[^#]).*)+/

CODE       = /^[-=]>/

MULTI_DENT = /^(?:\n[^\n\S]*)+/

SIMPLESTR  = /^'[^\\']*(?:\\[\s\S][^\\']*)*'/

JSTOKEN    = /^`[^\\`]*(?:\\.[^\\`]*)*`/

# Regex-matching-regexes.
REGEX = /// ^
  (/ (?! [\s=] )   # disallow leading whitespace or equals signs
  [^ [ / \n \\ ]*  # every other thing
  (?:
    (?: \\[\s\S]   # anything escaped
      | \[         # character class
           [^ \] \n \\ ]*
           (?: \\[\s\S] [^ \] \n \\ ]* )*
         ]
    ) [^ [ / \n \\ ]*
  )*
  /) ([imgy]{0,4}) (?!\w)
///

HEREGEX      = /// ^ /{3} ((?:\\?[\s\S])+?) /{3} ([imgy]{0,4}) (?!\w) ///

HEREGEX_OMIT = ///
    ((?:\\\\)+)     # consume (and preserve) an even number of backslashes
  | \\(\s|/)        # preserve escaped whitespace and "de-escape" slashes
  | \s+(?:#.*)?     # remove whitespace and comments
///g

# Token cleaning regexes.
MULTILINER      = /\n/g

HEREDOC_INDENT  = /\n+([^\n\S]*)/g

HEREDOC_ILLEGAL = /\*\//

LINE_CONTINUER  = /// ^ \s* (?: , | \??\.(?![.\d]) | :: ) ///

TRAILING_SPACES = /\s+$/

# Compound assignment tokens.
COMPOUND_ASSIGN = [
  '-=', '+=', '/=', '*=', '%=', '||=', '&&=', '?=', '<<=', '>>=', '>>>='
  '&=', '^=', '|=', '**=', '//=', '%%='
]

# Unary tokens.
UNARY = ['NEW', 'TYPEOF', 'DELETE', 'DO']

UNARY_MATH = ['!', '~']

# Logical tokens.
LOGIC = ['&&', '||', '&', '|', '^']

# Bit-shifting tokens.
SHIFT = ['<<', '>>', '>>>']

# Comparison tokens.
COMPARE = ['==', '!=', '<', '>', '<=', '>=']

# Mathematical tokens.
MATH = ['*', '/', '%', '//', '%%']

# Relational tokens that are negatable with `not` prefix.
RELATION = ['IN', 'OF', 'INSTANCEOF']

# Boolean tokens.
BOOL = ['TRUE', 'FALSE']

# Tokens which a regular expression will never immediately follow, but which
# a division operator might.
#
# See: http://www.mozilla.org/js/language/js20-2002-04/rationale/syntax.html#regular-expressions
#
# Our list is shorter, due to sans-parentheses method calls.
NOT_REGEX = ['NUMBER', 'REGEX', 'BOOL', 'NULL', 'UNDEFINED', '++', '--']

# If the previous token is not spaced, there are more preceding tokens that
# force a division parse:
NOT_SPACED_REGEX = NOT_REGEX.concat ')', '}', 'THIS', 'IDENTIFIER', 'STRING', ']'

# Tokens which could legitimately be invoked or indexed. An opening
# parentheses or bracket following these tokens will be recorded as the start
# of a function invocation or indexing operation.
CALLABLE  = ['IDENTIFIER', 'STRING', 'REGEX', ')', ']', '}', '?', '::', '@', 'THIS', 'SUPER']
INDEXABLE = CALLABLE.concat 'NUMBER', 'BOOL', 'NULL', 'UNDEFINED'

# Tokens that, when immediately preceding a `WHEN`, indicate that the `WHEN`
# occurs at the start of a line. We disambiguate these from trailing whens to
# avoid an ambiguity in the grammar.
LINE_BREAK = ['INDENT', 'OUTDENT', 'TERMINATOR']

# Additional indent in front of these is ignored.
INDENTABLE_CLOSERS = [')', '}', ']']
