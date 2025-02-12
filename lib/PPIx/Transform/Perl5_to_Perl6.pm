package PPIx::Transform::Perl5_to_Perl6;
use strict;
use warnings;
use Carp         qw( carp croak );
use Params::Util qw( _INSTANCE _ARRAY _ARRAY0 _STRING );
use base 'PPI::Transform';

BEGIN {
    # Before 1.204_03, PPI::Transform silently threw away all params to new().
    {
        no warnings 'numeric';
        use PPI::Transform 1.204 ();
    }
    my $ver = $PPI::Transform::VERSION;
    if ( $ver eq '1.204_01' or $ver eq '1.204_02' ) {
        die "PPI::Transform version 1.204_03 required--this is only version $ver";
    }
}

=head1 NAME

PPIx::Transform::Perl5_to_Perl6

A class to transform Perl 5 source code into equivalent Perl 6.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    use PPIx::Transform::Perl5_to_Perl6;

    my $transform = PPIx::Transform::Perl5_to_Perl6->new();

    # Read from one file and write to another
    $transform->file( 'some_perl_5_module.pm' => 'some_perl_5_module.pm6' );

    # Change a file in place
    $transform->file( 'some_perl_5_program.pl' );

    my $code_in = '$x = $y . $z';

    my $PPI_doc = PPI::Document->new( \$code_in ) or die;

    my $rc = $transform->apply($PPI_doc) or warn;

    my $code_out = $PPI_doc->serialize;
    # $code_out contains '$x = $y ~ $z'

    # Or, run this from the command line:
    #   bin/p526 path/to/program.pl > program_and_warnings.p6

=head1 DESCRIPTION

This class implements a document transform that will translate Perl 5 source
code into equivalent Perl 6.

=cut

=begin comments

2008-01-19  Bruce Gray
Wrote program.

This program will translate Perl 5 code into Perl 6. Mostly :)

Currently handles:
    Operator changes
    Invariant sigils
    Casts
    Nums with trailing.
    KeywordNoSpace
    Bare hash keys
    map/grep comma
    mapish EXPR changes to {BLOCK}
    Warnings for user review of transforms

=end comments

=cut


# Scaffolding to allow us to work as a PPI::Transform.
my %optional_initializer = map { $_ => 1 } qw( WARNING_LOG );
sub new {
    my $self = shift->SUPER::new(@_);

    my $bad = join "\n\t",
              grep { !$optional_initializer{$_} }
              sort keys %{$self};
    carp "Unexpected initializer keys are being ignored:\n$bad\n " if $bad;

    return $self;
}

sub document {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $document ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($document, 'PPI::Document');

    my $change_count = $self->_convert_Perl5_PPI_to_Perl6_PPI($document);

    # XXX Work-around for a bug in PPI.
    # PPI::Transform documentation on apply() says:
    #    Returns true if the transform was applied,
    #    false if there is an error in the transform process,
    #    or may die if there is a critical error in the apply handler.
    # but if the transform *is* applied without error, and no change happens
    # as a result, then apply() incorrectly returns undef.
    return 1 if defined $change_count and $change_count == 0;

    return $change_count;
}


# Converts the passed document in-place!
# Returns number of changes, 0 if not changes, undef on error.
sub _convert_Perl5_PPI_to_Perl6_PPI {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    $self->_fix_PPI_shift_equals_op_bug($PPI_doc);

    my $change_count = 0;
    $change_count += $self->_translate_all_ops($PPI_doc);
    $change_count += $self->_change_interpolations($PPI_doc);
    $change_count += $self->_change_sigils($PPI_doc);
    $change_count += $self->_change_regex($PPI_doc);
    $change_count += $self->_change_print_fh($PPI_doc);
    $change_count += $self->_change_octal($PPI_doc);
    $change_count += $self->_change_casts($PPI_doc);
    $change_count += $self->_change_trailing_fp($PPI_doc);
    $change_count += $self->_insert_space_after_keyword($PPI_doc);
    $change_count += $self->_clothe_the_bareword_hash_keys($PPI_doc);
    $change_count += $self->_add_a_comma_after_mapish_blocks($PPI_doc);
    $change_count += $self->_change_mapish_expr_to_block($PPI_doc);
    $change_count += $self->_change_foreach_my_lexvar_to_arrow($PPI_doc);
    $change_count += $self->_change_c_style_for_to_loop($PPI_doc);
    $change_count += $self->_remove_obsolete_pragmas_and_shbang($PPI_doc);
    $change_count += $self->_optionally_change_qw_to_arrow_quotes($PPI_doc);
    $change_count += $self->_remove_parens_from_conditionals($PPI_doc);
    $change_count += $self->_move_sub_params_from_at_to_declaration($PPI_doc);

    return $change_count;
}


# PPI Bug: += is a single operator, but <<= is two operators, << and = .
# <<= should be one operator. Same for >>= .
sub _fix_PPI_shift_equals_op_bug {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;

    my $ops_aref = $PPI_doc->find( 'PPI::Token::Operator' )
        or return;

    my @ops_to_delete;
    for my $op ( @{$ops_aref} ) {
        my $content = $op->content;

        next unless $content eq '<<'
                 or $content eq '>>';

        my $sib = $op->next_sibling
            or next;

        next unless $sib->class   eq 'PPI::Token::Operator'
                and $sib->content eq '=';

        $op->add_content('=');
        push @ops_to_delete, $sib;
    }

    $_->delete or warn for @ops_to_delete;

    return 1;
}


sub _get_all {
    croak 'Wrong number of arguments passed to sub' if @_ != 2;
    my ( $PPI_doc, $classname ) = @_;
    croak 'Parameter 1 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');
    croak 'Parameter 2 must be a classname!'     if !_STRING($classname);

    $classname = "PPI::$classname" if $classname !~ m{^PPI::};

    my $aref = $PPI_doc->find($classname)
        or return;

    return @{$aref};
}

# Each entry is either a straight translation,
# or a list of possible translations.
my %ops_translation = (
    '.'   =>   '~',
    '.='  =>   '~=',
    '->'  =>   '.',

    '=~'  =>   '~~',
    '!~'  =>   '!~~',

    # Ternary op
    '?'   => '??',
    ':'   => '!!',

    # Bitwise ops
    # http://perlcabal.org/syn/S03.html#Changes_to_Perl_5_operators
    #   Bitwise operators get a data type prefix: +, ~, or ?.
    #   For example, Perl 5's | becomes either +| or ~| or ?|, depending
    #   on whether the operands are to be treated as numbers, strings,
    #   or boolean values.
    # In Perl 5, the choice of whether to treat the operation as numeric or
    # string depended on the data; In Perl 6, it depends on the operator.
    # Note that Perl 6 has a short-circuiting xor operator, (^^). Since Perl 5
    # had no equivalent operator, nothing should translate to ^^, but we might
    # spot code that could advise the user to inspect for a ^^ opportunity.
    # Note that Perl 5 has separate ops for prefix versus infix xor
    # (~ versus ^). Perl 6 uses typed ^ for both prefix and infix.
    '|'   => [ '+|', '~|', '?|' ], # bitwise or  ( infix)
    '&'   => [ '+&', '~&', '?&' ], # bitwise and ( infix)
    '^'   => [ '+^', '~^', '?^' ], # bitwise xor ( infix)
    '~'   => [ '+^', '~^', '?^' ], # bitwise not (prefix)

    '<<'  => [ '+<', '~<' ], # bitwise shift left
    '>>'  => [ '+>', '~>' ], # bitwise shift right
    '<<=' => [ '+<=', '~<=' ], # bitwise shift assign left
    '>>=' => [ '+>=', '~>=' ], # bitwise shift assign right
);

# Returns number of changes, 0 if not changes, undef on error.
sub _translate_all_ops {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;

    my $change_count = 0;
    for my $op ( _get_all( $PPI_doc, 'Token::Operator' ) ) {
        my $p5_op = $op->content;

        my $p6_op = $ops_translation{$p5_op}
            or next;

        if ( _STRING($p6_op) ) {
            $op->set_content( $p6_op );
            $change_count++;
        }
        elsif ( _ARRAY($p6_op) ) {
            my @p6_ops = @{$p6_op};
            my $default_op = $p6_ops[0];

            my $possible_ops = join ', ', map { "'$_'" } @p6_ops;
            $self->log_warn(
                $op,
                "op '$p5_op' was"
               . " changed to '$default_op', but could have been"
               . " any of ( $possible_ops ). Verify the context!\n"
            );

            $op->set_content( $default_op );
            $change_count++;
        }
        else {
            carp "Don't know how to handle xlate of op '$p5_op'"
               . " (is the entry in %ops_translation misconfigured?)";
        }
    }

    return $change_count;
}

sub _change_sigils {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    # Easy, since methods raw_type and symbol_type already contain the
    # logic to look at subscripts to figure out the real type of the variable.
    # Handles $foo[5]       -> @foo[5]       (array element),
    #         $foo{$key}    -> %foo{$key}    (hash  element),
    #         @ARGV         -> @*ARGV
    #     and @foo{'x','y'} -> %foo{'x','y'} (hash  slice  ).
    #
    # No change needed for     @foo[1,5]     (array slice  ).

    my $count = 0;
    for my $sym ( _get_all( $PPI_doc, 'Token::Symbol' ) ) {
	if ($sym->symbol =~ /^\@ARGV$/) {
	    $sym->set_content( "@*ARGV" );
            $count++;
        }
        if ( $sym->raw_type ne $sym->symbol_type ) {
            $sym->set_content( $sym->symbol() );
            $count++;
        }
    }
    for my $sym ( _get_all( $PPI_doc, 'Token::ArrayIndex' ) ) {
	$sym =~ m/\$#(.+)/;
	my $array = "$1.end";
	$sym->set_content( ($1 =~ /^ARGV$/ ? "@*" : "@") . $array );
	$count++;
    }

    return $count;
}

sub _change_interpolations {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    # Easy, replace string interpolations
    # Handles ${var}    -> {$var}
    #         $foo{bar} -> %foo{bar}
    #         @foo[$i]  -> @foo[$i]

    my $count = 0;
    for my $quote ( _get_all( $PPI_doc, 'Token::Quote::Double' ) ) {
	next unless $quote->interpolations;
	my $str = $quote->string();
	$str =~ s/\$\{/{\$/g;
	$str =~ s/\$(\w+\{)/%$1/g;
	$str =~ s/\$(ARGV)\b/\@*$1/g;
	$str =~ s/\$(\w+\[)/\@$1/g;
	$quote->set_content( "\"$str\"" );
	$count++;
    }

    return $count;
}

sub _change_regex {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    my $count = 0;

    # Move modifiers at the end to the start of regex
    for my $regex ( _get_all( $PPI_doc, 'Token::Regexp' ) ) {
	my %mods = $regex->get_modifiers;
	next unless keys %mods;

	$self->log_warn(
	    $regex,
	    "Ignoring regex modifiers but clearing them"
	) if join('',keys %mods) !~ /[xig]+/;

	$_ = $regex->content;
	s#/\w+$#/#;
	for my $mod (sort(keys %mods)) {
	    s/^./$&:$mod / if $mod =~ /[ig]/;
	}
	$regex->set_content($_);
    }

    # Handles Error: Unrecognized regex metacharacter
    for my $regex ( _get_all( $PPI_doc, 'Token::Regexp' ) ) {
	next unless $regex =~ m/[`\-#=,]/;
	$regex->set_content( $regex->content =~ s/[`\-#=,]/\\$&/gr);
	$count++;
    }

    return $count;
}

sub _change_print_fh {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    # Changes `print FH "string";` to `FH.print: "string"`

    my $count = 0;
    for ( _get_all( $PPI_doc, 'Statement' ) ) {
	my @sc = $_->schildren;
	next if $sc[0] ne "print" ||
	@sc < 2 ||
	$sc[1]->class ne "PPI::Token::Word" ||
	$sc[1]->literal =~ /if|grep|map/;
	my @c = $_->children;
	my $f = shift @c;
	$f->delete();
	_eat_optional_whitespace(\@c);
	$c[0]->set_content( $c[0]->content =~ s/.+/$&.print:/r );
	$count++;
    }

    return $count;
}

sub _change_octal {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    # Easy, ` is a metacharacter in raku so changing ` to \` in regex match

    my $count = 0;
    for my $num ( _get_all( $PPI_doc, 'Token::Number::Octal' ) ) {
	$_ = $num;
	s/^0/0o/;
	$num->set_content( $_ );
	$count++;
    }

    return $count;
}

sub _change_casts {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    # PPI mis-parses `% $foo`, so we cannot easily convert to the
    # better-written '%($foo)'. See:
    #       bin/ppi_dump -e '%{$foo};' -e '%$foo;' -e '% $foo;' -e '% {$foo};'
    my $count = 0;
    for my $cast ( _get_all( $PPI_doc, 'Token::Cast' ) ) {
        my $s = $cast->next_sibling;
        if ( $s->isa('PPI::Token::Symbol') ) {
            # Don't do anything. %$foo is still a valid form in Perl 6.
        }
        elsif ( $s->isa('PPI::Token::Cast') and $cast eq "\\" ) {
            # Two casts in a row, like \% in \%{"$pack\:\:SUBS"} .
            # Skip for now.
        }
        elsif ( $s->isa('PPI::Structure::Block') ) {
            # %{...} becomes %(...). Same with @{...} and ${...}.
            if ( $s->start->content eq '{' and $s->finish->content eq '}' ) {
                 $s->start->set_content('(');
                $s->finish->set_content(')');
                $count++;
            }
        }
        elsif ( $s->isa('PPI::Structure::List') and $cast eq "\\" ) {
            # Don't do anything for now.
            # \( $x, $y ) is not the construct we are looking for.
        }
        else {
            $self->log_warn(
                $cast,
                'XXX May have mis-parsed a Cast - sibling class',
                ' ', $s->class,
                ' ', $s->content,
            );
        }
    }

    return $count;
}

sub _change_trailing_fp {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    # [S02] Implicit Topical Method Calls
    # ...you may no longer write a Num as C<42.> with just a trailing dot.
    my $count = 0;
    for my $fp ( _get_all( $PPI_doc, 'Token::Number::Float' ) ) {
        my $n = $fp->content;
        if ( $n =~ m{ \A ([_0-9]+) [.] \z }msx ) { # Could have underscore
            my $bare_num = $1;
            my $n0 = $n . '0';
            $fp->set_content( $n0 );
            $self->log_warn(
                $fp,
                "floating point number '$n' was changed to floating point number '$n0'. Consider changing it to integer '$bare_num'.",
            );
            $count++;
        }
    }

    return $count;
}

sub _insert_space_after_keyword {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    # [S03] Minimal whitespace DWIMmery
    # Whitespace is in general required between any keyword and any opening
    # bracket that is I<not> introducing a subscript or function arguments.
    # Any keyword followed directly by parentheses will be taken as a
    # function call instead.
    #     if $a == 1 { say "yes" }            # preferred syntax
    #     if ($a == 1) { say "yes" }          # P5-ish if construct
    #     if($a,$b,$c)                        # if function call
    #
    # [S04] Statement parsing
    # Built-in statement-level keywords require whitespace between the
    # keyword and the first argument, as well as before any terminating loop.
    # In particular, a syntax error will be reported for C-isms such as these:
    #     if(...) {...}
    #     while(...) {...}
    #     for(...) {...}

    my %wanted = (
        if       => { 'PPI::Structure::Condition' => 1, },
        unless   => { 'PPI::Structure::Condition' => 1, },
        elsif    => { 'PPI::Structure::Condition' => 1, },
        while    => { 'PPI::Structure::Condition' => 1, },
        until    => { 'PPI::Structure::Condition' => 1, },
        given    => { 'PPI::Structure::Given'     => 1, },
        when     => { 'PPI::Structure::When'      => 1,
                      'PPI::Structure::List'      => 1, },
        for      => { 'PPI::Structure::List'      => 1,
                      'PPI::Structure::For'       => 1, },
        foreach  => { 'PPI::Structure::List'      => 1,
                      'PPI::Structure::For'       => 1, },
    );
    my $count = 0;
    for my $keyword ( _get_all( $PPI_doc, 'Token::Word' ) ) {
        my $expected_sib_types_href = $wanted{$keyword}
            or next;

        my $sib = $keyword->next_sibling
            or next;

        my $c = $sib->class
            or next;

        if ( $expected_sib_types_href->{$c} ) {
            my $space = PPI::Token::Whitespace->new(' ');
            $keyword->insert_after($space);
            $count++;
        }
    }

    return $count;
}

sub _only_schild {
    croak 'Wrong number of arguments passed to sub' if @_ != 2;
    my ( $element, $class ) = @_;

    my @ss_kids = $element->schildren;
    return unless @ss_kids == 1;
    my $child = $ss_kids[0];
    return unless $child->isa($class);
    return $child;
}

sub _clothe_the_bareword_hash_keys {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    # Translate all the bareword hash keys into single-quote.
    my $count = 0;
    for my $subscript ( _get_all( $PPI_doc, 'Structure::Subscript' ) ) {

        # Must have this structure:
        #        PPI::Token::Symbol          '$z'
        #        PPI::Structure::Subscript   { ... }
        #          PPI::Statement::Expression
        #            PPI::Token::Word        'foo'

        next unless $subscript->sprevious_sibling->isa('PPI::Token::Symbol');

        next unless substr( $subscript,  0, 1 ) eq '{'
                and substr( $subscript, -1, 1 ) eq '}';

        my $expression = _only_schild($subscript, 'PPI::Statement::Expression')
            or next;

        my $word = _only_schild($expression, 'PPI::Token::Word')
            or next;

        my $quoted_word  = "'" . $word->content . "'";
        my $quoted_token = PPI::Token::Quote::Single->new($quoted_word);

        # Cannot use replace() because $quoted_token and $word differ in type.
        $word->insert_after($quoted_token) or warn;
        $word->delete or warn;

        $count++;
    }

    return $count;
}

sub _add_a_comma_after_mapish_blocks {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    my %wanted_words = map { $_ => 1 } qw( map grep );

    # Add a comma after the block in `map BLOCK` or `grep BLOCK`.
    my $count = 0;
    for my $word ( _get_all( $PPI_doc, 'Token::Word' ) ) {
        # Must have this structure:
        # PPI::Token::Word          'map' (or 'grep')
        # PPI::Structure::Block     { ... }

        next unless $wanted_words{ $word->content };

        my $sib = $word->snext_sibling;
        next unless $sib->isa('PPI::Structure::Block');

        my $comma = PPI::Token::Operator->new(',');
        $sib->insert_after($comma) or warn;

        $count++;
    }
    return $count;
}

sub _change_mapish_expr_to_block {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    my %wanted_words = map { $_ => 1 } qw( map grep );

    # Change `map $_ * 5, @z` to `map { $_ * 5 }, @z`
    my $count = 0;
    for my $word ( _get_all( $PPI_doc, 'Token::Word' ) ) {
        # Must have this structure:
        #   PPI::Token::Word      'map'
        #   ... NOT PPI::Structure::Block
        #   PPI::Token::Operator      ','
        # Changing to this new structure:
        #   PPI::Token::Word  	'map'
        #   PPI::Structure::Block  	{ ... }
        #     PPI::Statement
        #       ... from original version
        #     PPI::Token::Operator      ','

        next unless $wanted_words{ $word->content };

        my $next_ssib = $word->snext_sibling;
        next if $next_ssib->isa('PPI::Structure::Block');

        # Can't use find() here because we need to search *forward* from $word,
        # not *down* within $word.

        my $last_sib = $next_ssib; # Can't be a comma, since `map ,` is invalid
        my @elements_to_move = $last_sib;
        while ( $last_sib = $last_sib->next_sibling ) {
            last if $last_sib->isa('PPI::Token::Operator')
                and $last_sib->content eq ',';
            push @elements_to_move, $last_sib;
        }
        next unless $last_sib;

        my $new_block = _make_a_block();
        $next_ssib->insert_before($new_block) or die;

        my $needs_leading_ws  = not $elements_to_move[ 0]->isa('PPI::Token::Whitespace');
        my $needs_trailing_ws = not $elements_to_move[-1]->isa('PPI::Token::Whitespace');
        my $s = PPI::Statement->new();
        $s->add_element( PPI::Token::Whitespace->new(' ') ) if $needs_leading_ws;
        $_->remove          or die for @elements_to_move;
        $s->add_element($_) or die for @elements_to_move;
        $s->add_element( PPI::Token::Whitespace->new(' ') ) if $needs_trailing_ws;

        $new_block->add_element($s)
            or die;

        $count++;
    }
    return $count;
}

sub _change_foreach_my_lexvar_to_arrow {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    my %wanted_words = map { $_ => 1 } qw( for foreach );

    # XXX Need to log info on ro vs rw!
    # XXX Need to force foreach to for!

    # Also, named lex vars in `foreach` loops are read-write in Perl 5, but read-only by default in Perl 6.
    #   Either make my generated code be rw, and log a message to go back and replace with ro as an optimization
    #       or generate as ro, and log a message that it might not work!

    # XXX Add code to trim the whitespace when parens are removed around something that already has whitespace.

    # Change `for my $i (@a)` to `for @a -> $i`
    my $count = 0;
    for my $statement ( _get_all( $PPI_doc, 'Statement::Compound' ) ) {
        # Must have this structure:
        #   PPI::Statement::Compound
        #     PPI::Token::Word  	'for' (or foreach)
        #     PPI::Token::Word  	'my' # Optional - and XXX need to warn when encountered?
        #     PPI::Token::Symbol  	'$i' # Optional - use $_ when missing
        #     PPI::Structure::List  	( ... )
        #       PPI::Statement
        #         ...
        # Changing to this new structure:
        #   PPI::Statement::Compound
        #     PPI::Token::Word  	'for' (or foreach)
        #     PPI::Structure::List  	 ...
        #       PPI::Statement
        #         ...
        #     PPI::Token::Operator  	'->'
        #     PPI::Token::Symbol  	'$i'

        my @sc = $statement->schildren;
        next unless @sc and $sc[0] and $sc[0]->class() eq 'PPI::Token::Word'
                and $wanted_words{ $sc[0]->content };
        next unless @sc >= 4
                and $sc[1]->class() eq 'PPI::Token::Word'     and $sc[1]->content eq 'my'
                and $sc[2]->class() eq 'PPI::Token::Symbol'
                and $sc[3]->class() eq 'PPI::Structure::List'
                 or @sc >= 3
                and $sc[1]->class() eq 'PPI::Token::Symbol'
                and $sc[2]->class() eq 'PPI::Structure::List'
                 or @sc >= 2
                and $sc[1]->class() eq 'PPI::Structure::List';

        my @c = $statement->children;

        _eat_optional_whitespace(\@c); # XXX Can this really occur here?

        # Change keyword "foreach" to "for" if needed.
        # Keyword is not needed in @c after this point.
        {
            my $k = shift @c or die;
            die unless $k->class eq 'PPI::Token::Word' and $wanted_words{ $k->content };

            # $k->replace( PPI::Token::Word->new('for') ) if $k->content eq 'foreach'; # XXX The ->replace method has not yet been implemented in PPI 1.215.
            if ( $k->content eq 'foreach' ) {
                my $new_k = PPI::Token::Word->new('for')    or die;
                $k->insert_after($new_k)                    or die;
                $k->delete()                                or die;
            }
        }

        _eat_optional_whitespace(\@c);

        # Peek at next element.
        # Remove `my` if it was there, and register whether it was there, for later use.
        my $had_my;
        {
            die if not @c;
            $had_my = (     $c[0]->class() eq 'PPI::Token::Word'
                        and $c[0]->content eq 'my' );
            if ($had_my) {
                my $keyword_my = shift @c or die;
                   $keyword_my->delete    or die;
            }
        }

        _eat_optional_whitespace(\@c);

        # Peek at next element.
        # Remove $VAR if it was there, and register $VAR, or $_ if absent.
        my $var;
        {
            die if not @c;
            if ( $c[0]->class() eq 'PPI::Token::Symbol' ) {
                $var = shift @c or die;
                $var->remove or die;
            }
            else {
                $var = PPI::Token::Magic->new( '$_' );
            }
        }
        # die unless @c and $c[0]->class eq 'PPI::Token::Symbol';
        # my $var = shift(@c)->remove or die;

        _eat_optional_whitespace(\@c);

        # Remove parens from (LIST)
        die unless @c and $c[0]->class eq 'PPI::Structure::List';
        my $sl = $c[0];
        die unless $sl->start ->content eq '('
               and $sl->finish->content eq ')';
        $sl->start ->set_content('');
        $sl->finish->set_content('');

	$sl->insert_before( PPI::Token::Whitespace->new(' ') );
        $sl->insert_after($_) for reverse (
            PPI::Token::Whitespace->new(' '),
            PPI::Token::Operator  ->new('<->'), # XXX Fixup with log message. In fact, make it an option.
            PPI::Token::Whitespace->new(' '),
            $var,
        );

        $count++;
    }
    return $count;
}

sub _change_c_style_for_to_loop {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    my %wanted_words = map { $_ => 1 } qw( for );

    # XXX Add code to trim the whitespace when parens are removed around something that already has whitespace.

    # Change `for (my $i = 0; $i < 3; $i++) {}` to `loop (my $i = 0; $i < 3; $i++) {}`
    my $count = 0;
    for my $statement ( _get_all( $PPI_doc, 'Statement::Compound' ) ) {
        # Must have this structure:
        #   PPI::Statement::Compound
        #     PPI::Token::Word  	'for'
        #     PPI::Structure::For  	(my $i = 0; $i < 3; $i++) 
        #       PPI::Statement
        #         ...
        # Changing to this new structure:
        #   PPI::Statement::Compound
        #     PPI::Token::Word  	'loop'
        #     PPI::Structure::For  	(my $i = 0; $i < 3; $i++) 
        #       PPI::Statement

        my @sc = $statement->schildren;
        next unless @sc and $sc[0] and $sc[0]->class() eq 'PPI::Token::Word'
                and $wanted_words{ $sc[0]->content };
        next unless @sc == 3 and $sc[1]->class() eq 'PPI::Structure::For';

        my @c = $statement->children;

        _eat_optional_whitespace(\@c); # XXX Can this really occur here?

        # Change keyword "for" to "loop"
        # Keyword is not needed in @c after this point.
        {
            my $k = shift @c or die;
            die unless $k->class eq 'PPI::Token::Word' and $wanted_words{ $k->content };

            # $k->replace( PPI::Token::Word->new('loop') ) ; # XXX The ->replace method has not yet been implemented in PPI 1.215.
            if ( $k->content eq 'for' ) {
                my $new_k = PPI::Token::Word->new('loop')   or die;
                $k->insert_after($new_k)                    or die;
                $k->delete()                                or die;
            }
        }

        $count++;
    }
    return $count;
}

sub _remove_obsolete_pragmas_and_shbang {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    # PPI::Token::Comment               '#!/usr/bin/env perl\n'
    # PPI::Statement::Include
    #   PPI::Token::Word                'use'
    #   PPI::Token::Word                'strict'
    #   PPI::Token::Structure           ';'
    # PPI::Statement::Include
    #   PPI::Token::Word                'use'
    #   PPI::Token::Word                'warnings'
    #   PPI::Token::Structure           ';'

    my $count = 0;

    # XXX Improve handling of whitespace removal.
    # XXX Add "use v6;" ???

    # XXX Restructure to look at siblings instead?
    # XXX remove_child vs delete???
    my $first_non_ws_element = $PPI_doc->find_first( sub { not $_[1]->isa('PPI::Token::Whitespace') } )
        or return;
    if ( $first_non_ws_element->isa('PPI::Token::Comment') ) {
        if ( $first_non_ws_element =~ m{ \A \s* [#]!/usr/bin/ (?:perl|env\s+perl) \s* \z }msx ) {
            my $ws;
            if ( $ws = $first_non_ws_element->next_sibling and $ws->isa('PPI::Token::Whitespace') ) {
                $PPI_doc->remove_child($ws);
                $count++;
            }
            $PPI_doc->remove_child($first_non_ws_element);
            $count++;

            my $e1;
            while ( $e1 = $PPI_doc->find_first(sub {1}) and $e1->isa('PPI::Token::Whitespace') ) {
                $PPI_doc->remove_child($e1);
                $count++;
            }
        }

    }

    for my $include ( _get_all( $PPI_doc, 'Statement::Include' ) ) {
        # XXX Add code to issue info about the removal
        # XXX Add code to give more info on specific warnings and on partial strict.
        if ( $include =~ m{ \A \s* use \s+ (?:strict|warnings) \s* [;]? \s* \z }msx ) {
            my $ws;
            if ( $ws = $include->next_sibling and $ws->isa('PPI::Token::Whitespace') ) {
                $PPI_doc->remove_child($ws);
                $count++;
            }
            $PPI_doc->remove_child($include);
            $count++;
        }
    }

    return $count;
}

# XXX Relies on the fact that PPI parses the whitespace inside the parens as being outside of them.
sub _remove_parens_from_conditionals {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');
    # PPI::Statement::Compound
    #   PPI::Token::Word                'if'
    #   PPI::Structure::Condition       ( ... )
    #     PPI::Statement::Expression              $x eq $y
    #   PPI::Structure::Block           { ... }   say "Hi"
    #   PPI::Token::Word                'elsif'
    #   PPI::Structure::Condition       ( ... )
    #     PPI::Statement::Expression              $x gt $y
    #   PPI::Structure::Block           { ... }   say "Ho"
    #   PPI::Token::Word                'elsif'
    #   PPI::Structure::Condition       ( ... )
    #     PPI::Statement::Expression              $x le $y
    #   PPI::Structure::Block           { ... }   say "He"

    my %wanted = map { $_ => 1 } qw( if elsif unless while until );

    my $count = 0;
    for my $compound ( _get_all( $PPI_doc, 'Statement::Compound' ) ) {
        my @sc = $compound->schildren;

        for my $i ( 0+1 .. $#sc-1 ) {
            my ( $prior, $this, $next ) = @sc[ $i-1, $i, $i+1 ];

            next if $this->class ne 'PPI::Structure::Condition';

            warn if $prior->class ne 'PPI::Token::Word'
                 or !$wanted{$prior->content};

            warn if $next->class ne 'PPI::Structure::Block';

            warn if $this->start ->content ne '('
                 or $this->finish->content ne ')';

            # Remove the parens
            $this->start ->set_content('');
            $this->finish->set_content('');
            $count++;

            # Fix the whitespace
            my $express;
            if ( $express = _only_schild( $this, 'PPI::Statement::Expression' )
              or $express = _only_schild( $this, 'PPI::Statement' )
            ) {
                my $sib;
                while ( $sib = $express->next_sibling     and $sib->class eq 'PPI::Token::Whitespace' ) {
                    $sib->delete or warn;
                }
                while ( $sib = $express->previous_sibling and $sib->class eq 'PPI::Token::Whitespace' ) {
                    $sib->delete or warn;
                }
            }
            else {
                warn 'XXX Unexpected PPI below condition';
            }

            # If `while ($a){` , with no space before the brace, insert space
            if ( $next->previous_sibling == $this ) {
                my $space = PPI::Token::Whitespace->new(' ');
                $this->insert_after($space);
            }
        }
    }

    return $count;
}

# XXX First pass at this optional refactoring.
# XXX Needs to handle lots more variations, and recent Perl 5 sub-signatures.
# XXX Currently fails to inform user about `my ( $first, @rest ) = @_`.
# XXX Currently fails to process `my @args = @_`.
sub _move_sub_params_from_at_to_declaration {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');
    # PPI::Statement::Sub
    #   PPI::Token::Word                   'sub'
    #   PPI::Token::Word                   'abc'
    #   PPI::Structure::Block              { ... }
    #     PPI::Statement::Variable
    #       PPI::Token::Word               'my'
    #       PPI::Structure::List           ( ... )
    #         PPI::Statement::Expression
    #           PPI::Token::Symbol         '$a'
    #           PPI::Token::Operator       ','
    #           PPI::Token::Symbol         '$b'
    #           PPI::Token::Operator       ','
    #           PPI::Token::Symbol         '$c'
    #       PPI::Token::Operator           '='
    #       PPI::Token::Magic              '@_'
    #       PPI::Token::Structure          ';'

    my $count = 0;
    for my $sub ( _get_all( $PPI_doc, 'Statement::Sub' ) ) {
	next if $sub->forward;
	my ($sub_word, $sub_name) = $sub->schildren();
	my $block = $sub->block();

	my @sc = $sub->schildren;
	warn if $sub_name->class   ne 'PPI::Token::Word';

        my ($sv, @junk2) = $block->schildren;
        if ( $sv->class ne 'PPI::Statement::Variable' ) {
            $self->log_warn(
                $sv,
                "sub not given a param definition, "
               . "because the first statement within the sub was not `my`.\n"
            );
            next;
        }

        my ( $my_word, $list, $op, $underscore, $semi, @rest ) = $sv->schildren;
        warn if $my_word   ->class   ne 'PPI::Token::Word'
             or $my_word   ->content ne 'my';
        if (
            $list      ->class   ne 'PPI::Structure::List'
         or $op        ->class   ne 'PPI::Token::Operator'
         or $op        ->content ne '='
         or $underscore->class   ne 'PPI::Token::Magic'
         or $underscore->content ne '@_'
         or $semi      ->class   ne 'PPI::Token::Structure'
         or $semi      ->content ne ';'
        ) {
            $self->log_warn(
                $sv,
                "sub not given a param definition, "
               . "because the first statement within the sub was `my`, "
               . "but did not have a structure we recognize (yet).\n"
            );
            next;
        }

        my $space = PPI::Token::Whitespace->new(' ');
        $sub_name->insert_after($space);
        $list->remove;
        # XXX No good way to insert this so that future passes recognize it, unless we add custom types to PPI.
        $space->insert_after($list);
        my $sib;
        while ( $sib = $sv->next_sibling and $sib->class eq 'PPI::Token::Whitespace' ) {
            $sib->delete or warn;
        }
        $sv->delete;
        $count++;
    }
}

sub _optionally_change_qw_to_arrow_quotes {
    croak 'Wrong number of arguments passed to method' if @_ != 2;
    my ( $self, $PPI_doc ) = @_;
    croak 'Parameter 2 must be a PPI::Document!' if !_INSTANCE($PPI_doc, 'PPI::Document');

    # PPI::Statement::Variable
    #   PPI::Token::Word                'my'
    #   PPI::Token::Symbol              '@aaa'
    #   PPI::Token::Operator            '='
    #   PPI::Token::QuoteLike::Words    'qw( a b c d e f g )'
    #   PPI::Token::Structure           ';'

    my $count = 0;

    # qw is valid with any paired delimiters, *except* parens, which would make it a sub call.
    for my $qw ( _get_all( $PPI_doc, 'Token::QuoteLike::Words' ) ) {
        if ( $qw =~ m{ \A qw\(( .+ )\) \z }msx ) {
            $qw->set_content( "<$1>" );
            $count++;
        }
    }

    return $count;
}

sub _make_a_block {
    croak 'Wrong number of arguments passed to method' if @_;

    # XXX Flaw in PPI: Cannot simply create PPI::Structure::* with ->new().
    # See https://rt.cpan.org/Public/Bug/Display.html?id=31564
    my $new_block = PPI::Structure::Block->new(
        PPI::Token::Structure->new('{'),
    ) or die;
    $new_block->{finish} = PPI::Token::Structure->new('}');

    return $new_block;
}

sub _eat_optional_whitespace {
    my ($elements_aref) = @_;
    return unless @{$elements_aref}
              and   $elements_aref->[0]->class eq 'PPI::Token::Whitespace';
    $elements_aref->[0]->delete or die;
    shift @{$elements_aref};
    return;
}

sub log_warn {
    my ( $self, $loc, @message_parts ) = @_;
    my $message = join '', @message_parts;

    # $loc indicates the location where the warning or error occurred.
    # It could be an object that provides a location method,
    # or a hand-constructed location aref, or undef.
    my @location
        = !$loc                           ? ()
        : _ARRAY($loc)                    ? @{ $loc             }
        : _INSTANCE($loc, 'PPI::Element') ? @{ $loc->location() }
        : croak("Unknown type passed as location object: ".ref($loc))
        ;

    if (@location) {
        # Before PPI-1.204_05, ->location() only returned 3 elements.
        my ( $line, $rowchar, $col, $logical_line, $logical_file_name ) = @location;

        my $pos = $rowchar eq $col ? $col : "$rowchar/$col";

        $message = "At line $line, position $pos, " . $message;
    }

    my $log_aref = $self->{WARNING_LOG};
    if ( _ARRAY0($log_aref) ) {
        push @{$log_aref}, $message;
    }
    else {
        carp $message;
    }

    return;
}

1;

=head1 TODO

Move the rest of the original code slush into place.

For each Planned/TODO item in the README file, add code to either implement the change or to warn about manual changes needed.

Need to add an configuration option on how to translate `for` ( -> vs <-> ).
Need to handle adding a informational note when translating for statements into <->, that it may be able to be shortened  to  -> .
Need to handle adding a informational note when translating for statements into  ->, that it may be need to be lengthened to <-> .

=head1 SUPPORT

Please submit a ticket to:
    https://github.com/Util/Blue_Tiger/issues

Emails sent directly to the original author might be answered, but the discussion could not then be found and read by others.

=head1 AUTHOR

Bruce Gray E<lt>bgray@cpan.orgE<gt>

=head1 COPYRIGHT

Copyright 2010-2011 Bruce Gray.

This program is free software; you can redistribute it and/or modify it under
the terms of version 2.0 of the Artistic License.

The full text of the license can be found in the LICENSE file included with
this module.

=cut
