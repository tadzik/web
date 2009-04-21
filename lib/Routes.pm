class Routes;
use Routes::Route;

has               @.routes;
has Callable      $.default is rw;

multi method add (Routes::Route $route) {
    die "Only complete routes allowed" unless $route.?is_complete;
    @!routes.push($route);
}

multi method add (@pattern, Code $code) {
    @!routes.push: Routes::Route.new( pattern => @pattern, code => $code, |%_);
}

# draft
method connect (@pattern, *%_ is rw) {
    %_<controller> //= 'Root';
    %_<action> //= 'index';
    %_<code> //= { %*controllers{$!controller}.$!action(|@_, |%_) };
    @!routes.push: Routes::Route.new( pattern => @pattern, |%_ );
}

# I think it should work as I mean without this one
multi method dispatch (@chunks) { self.dispatch(@chunks, Hash.new) }

multi method dispatch (@chunks, %param) {
#multi method dispatch (@chunks, %param?) {
    my @matched =  @!routes.grep: { .match(@chunks) };    
    
    if @matched {
        my $result = @matched[*-1].apply(%param);
        .clear for @!routes; 
        return $result;
    }
    elsif defined $.default {
        $.default();
    }
    else {
        return Failure;
    }
}

# draft
multi method dispatch ($request) {
    my %params;
    %params<request> = $request;
    %params<post>    = $request.POST;
    %params<get>     = $request.GET;

    # Use param as method first because HTML4 does not support PUT and DELETE
    %params<method> = %params<post><request_method> || $request.request_method;

    # Do not find this .path-chunks in rack request object, 
    # but I hope we will add something like this with chunks from URI.pm
    self.dispatch($request.path-chunks, %params);
}
# vim:ft=perl6
