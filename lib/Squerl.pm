use SQLite3;

class Squerl::InvalidOperation is Exception {
    has $.message;

    multi method new($message) {
        self.bless(*, :$message);
    }

    method Str() {
        "{self.WHAT}: $!message";
    }
}

class Squerl::Dataset does Positional {
    has $.db;
    has %.opts;
    # RAKUDO: Cannot type this attribute as Bool
    has $.quote_identifiers is rw;
    has Str $.identifier_input_method is rw;
    has Str $.identifier_output_method is rw;
    has &.row_proc is rw;

    my $COMMA_SEPARATOR = ', ';

    multi method new($db, :$quote_identifiers,
                     :$identifier_input_method, :$identifier_output_method,
                     :$row_proc,
                     *%opts) {
        self.bless(self.CREATE(), :$db, :$quote_identifiers,
                                  :$identifier_input_method,
                                  :$identifier_output_method,
                                  :$row_proc,
                                  :%opts);
    }

    multi method clone(*%opts) {
        my %new-opts = %!opts, %opts;
        self.bless(self.CREATE(), :db($!db),
                                  :quote_identifiers($!quote_identifiers),
                                  :identifier_input_method(
                                     $!identifier_input_method
                                   ),
                                  :identifier_output_method(
                                     $!identifier_output_method
                                   ),
                                  :row_proc(&!row_proc),
                                  :opts(%new-opts));
    }

    method from(*@tables) {
        self.clone(:from(@tables.elems > 1 ?? @tables !! @tables[0]));
    }

    method filter($value) {
        self.clone(:filter($value));
    }

    method insert(*@values) {
        my $values = @values>>.perl.join(', ');
        given $!db {
            .open;
            # RAKUDO: Real string interpolation
            .exec("INSERT INTO {%!opts<table>} VALUES($values)");
            .close;
        }
    }

    method all() {
        $!db.select("*", %!opts<table>);
    }

    method literal($value? is copy) {
        $value //= %_.pairs[0];
        given $value {
            when Int { return literal_integer($value) }
            when Num { return literal_number($value) }
            when Str { return literal_string($value) }
            when Pair { return self.literal_symbol($value.key) }
        }
    }

    method literal_symbol($name is copy) {
        $!identifier_input_method
          = { 'upcase' => 'uc', 'downcase' => 'lc',
              'reverse' => 'flip' }.{$!identifier_input_method}
            // $!identifier_input_method;
        if $!identifier_input_method {
            # RAKUDO: Would like to have spaces around the operator:
            #         [perl #69204]
            $name.="$!identifier_input_method";
        }
        $!quote_identifiers ?? quoted_identifier($name) !! $name;
    }

    submethod literal_array(@values) {
        "({join $COMMA_SEPARATOR, map { self.literal($^value) }, @values})";
    }

    sub literal_integer($value) {
        ~$value
    }

    sub literal_number($value) {
        ~$value
    }

    sub literal_string($value) {
        "'{$value.subst('\\', '\\\\', :g).subst("'", "''", :g)}'"
    }

    sub quoted_identifier($name) {
        qq["{$name.subst(q["], q[""], :g)}"]
    }

    method output_identifier($name is copy) {
        $!identifier_output_method
          = { 'upcase' => 'uc', 'downcase' => 'lc',
              'reverse' => 'flip' }.{$!identifier_output_method}
            // $!identifier_output_method;
        if $!identifier_output_method {
            # RAKUDO: Would like to have spaces around the operator:
            #         [perl #69204]
            $name.="$!identifier_output_method";
        }
        $name;
    }

    method static_sql($sql) {
        $sql
    }

    method select_sql() {
        return self.static_sql(%!opts<sql>)
            if %!opts.exists('sql');

        # RAKUDO: Real string interpolation
        "SELECT * FROM {%!opts<from>}"
        ~ (%!opts.exists('filter')
            ?? " WHERE ({%!opts<filter>.fmt('%s = %s')})"
            !! '');
    }

    method delete_sql() {
        return self.static_sql(%!opts<sql>)
            if %!opts.exists('sql');

        # RAKUDO: Real string interpolation
        "DELETE FROM {%!opts<from>}";
    }

    method truncate_sql() {
        return self.static_sql(%!opts<sql>)
            if %!opts.exists('sql');

        # RAKUDO: Real string interpolation
        "TRUNCATE TABLE {%!opts<from>}";
    }

    method insert_sql(*@positionals, *%nameds) {
        return self.static_sql(%!opts<sql>)
            if %!opts.exists('sql');

        my (@columns, @values);
        for @positionals {
            when Pair {
                @columns.push(.key);
                @values.push(.value);
            }
            when Num|Str|Squerl::Dataset {
                @values.push($_);
            }
            when .^can('values') {
                for .values.pairs {
                    die "Expected a Pair, got a {.WHAT}"
                        unless $_ ~~ Pair;
                    @columns.push(.key);
                    @values.push(.value);
                }
            }
        }
        for %nameds.pairs {
            @columns.push(.key);
            @values.push(.value);
        }
        my $columns = @columns ?? "({join $COMMA_SEPARATOR, @columns}) "
                               !! '';
        my $values = @values
                       ?? (@values[0] ~~ Squerl::Dataset
                          ?? @values[0].select_sql()
                          !! 'VALUES ' ~ self.literal_array(@values))
                       !! 'DEFAULT VALUES';
        # RAKUDO: Real string interpolation
        "INSERT INTO {%!opts<from>} $columns$values";
    }

    method update_sql(*%nameds) {
        return self.static_sql(%!opts<sql>)
            if %!opts.exists('sql');

        die ~Squerl::InvalidOperation.new('Joined datasets cannot be modified')
            if %!opts<from> ~~ Array && %!opts<from>.elems > 1;

        my $values = join $COMMA_SEPARATOR, map {
            "{.key} = {self.literal(.value)}"
        }, %nameds.pairs;
        "UPDATE {%!opts<from>} SET $values";
    }
}

class Squerl::Database {
    has $!file;
    has $!dbh;
    # RAKUDO: Cannot type this attribute as Bool
    has $.quote_identifiers;
    has Str $.identifier_input_method;
    has Str $.identifier_output_method;

    method open() {
        $!dbh = sqlite_open($!file);
    }

    method close() {
        $!dbh.close();
    }

    method exec($statement) {
        my $sth = $!dbh.prepare($statement);
        $sth.step();
        $sth.finalize();
    }

    method create_table($_: *@args) {
        my $table-name = @args[0];
        my $columns = join ', ', gather for @args[1..^*] -> $type, $name {
            given $type.lc {
                when 'primary_key'   { take "$name INTEGER PRIMARY KEY ASC" }
                when 'int'|'integer' { take "$name INTEGER" }
                when 'str'|'string'  { take "$name TEXT" }
                default              { die "Unknown type $type" }
            }
        };
        .open;
        .exec("CREATE TABLE $table-name ($columns)");
        .close;
    }

    method select($_: $what, $table) {
        my @rows;
        .open;
        my $sth = $!dbh.prepare("SELECT $what FROM $table");
        while $sth.step() == 100 {
            push @rows, [map { $sth.column_text($_) }, ^$sth.column_count()];
        }
        .close;
        return @rows;
    }

    method from($table) {
        return Squerl::Dataset.new(self, :$table,
                                   :quote_identifiers($!quote_identifiers),
                                   :identifier_input_method(
                                     $!identifier_input_method
                                   ),
                                   :identifier_output_method(
                                     $!identifier_output_method
                                   ));
    }
}

class Squerl {
    method sqlite($file) {
        return Squerl::Database.new(:$file);
    }
}
