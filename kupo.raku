#!/usr/bin/env raku
#       ♥
#    /\__\__/\
#   /         \
# \(ﾐ  ⌒ ● ⌒  ﾐ)/

constant $default-config-file = 'config.yml';
constant $default-compose-file = 'docker-compose.yml';
constant $default-compose-prod-file = 'docker-compose.production.yml';

my %config;

proto sub MAIN(|) {
    load-config;
    return {*};
}

sub GENERATE-USAGE(&main, |capture) {
    splash "i'm here to help, kupo!";
    &*GENERATE-USAGE(&main, |capture)
}
               
multi sub MAIN('deploy',
    *@containers,
) {
    splash "deploying {@containers ?? @containers.elems !! 'all'} container{@containers.elems == 1 ?? '' !! 's'}, kupo!";
    @containers = validate-containers(@containers);
    
    deploy %config<deploy_path><>.IO, @containers;
    up %config<deploy_path><>.IO.add($default-compose-prod-file), @containers;
}

multi sub MAIN('up',
    *@containers,
) {
    splash "bringing up {@containers ?? @containers.elems !! 'all'} container{@containers.elems == 1 ?? '' !! 's'}, kupo!";
    up %config<deploy_path><>.IO.add($default-compose-prod-file), validate-containers(@containers);
}

multi sub MAIN('down',
    *@containers,
) {
    splash "bringing down {@containers ?? @containers.elems !! 'all'} container{@containers.elems == 1 ?? '' !! 's'}, kupo!";
    down %config<deploy_path><>.IO.add($default-compose-prod-file), validate-containers(@containers);
}

multi sub MAIN('log',
    Str $container
) { }

sub deploy(IO() $deploy-path, @containers)
{
    use YAMLish;
    if $deploy-path !~~ :d { die 'invalid deploy path specified!'; }

    # setup working temp dir
    my $build-path = $*TMPDIR.add("rakupo-{now.to-posix[0].int}");
    my $var-path = $build-path.add('var');

    # setup containers and build hash of methods to override compose file
    my %setup-container-compose = @containers>>.&{ setup-container $_, :$var-path }

    # create data symlink
    my $data-symlink = $build-path.add('data');
    symlink %config<data_path>, $data-symlink;

    # deploy etc directory
    if './etc'.IO ~~ :d {
        copy-tree './etc', $build-path;
        find($build-path.add('etc'), :type('f'))>>.&substitute-config-tokens;
    }

    # deploy images needed locally
    copy-tree './images', $build-path if './images'.IO ~~ :d;

    # generate the production docker compose file
    my $compose = load-yaml($default-compose-file.IO.slurp);
    for $compose<services>.kv -> $key, $service {
        $compose<services>{$key} = %setup-container-compose{$key}($service);
            
        if $compose<services>{$key}<volumes>:exists {
            for $compose<services>{$key}<volumes><> {
                when Str {
                    my $volume = $_.split(':');
                    $_ = (slip fix-relative-path($volume[0], $build-path).Str, $volume[1..*]).join(':');
                }
                when Hash {
                    if $_<source>:exists { $_<source> = fix-relative-path($_<source>, $build-path).Str; }
                };
            }
        }
    }

    # create any missing secrets
    my $secrets-path = $build-path.add('secrets');
    mkdir $secrets-path if $secrets-path !~~ :d;
    for $compose<secrets>.kv -> $key, $secret {
        my $secret-path = $secrets-path.add($key);
        if $secret-path !~~ :f {
            $secret-path.spurt: ('a'..'z', 'A'..'Z', 0..9).flat.roll(64).join;
            $secret-path.chmod: 0o600;
        }
        $compose<secrets>{$key}<file> = $secret-path.resolve.Str;
    }

    $build-path.add($default-compose-prod-file).spurt: save-yaml($compose);

    # copy to deploy path
    $build-path.dir>>.&{ copy-tree $_, $deploy-path }
    find($deploy-path)>>.&{ $_.chown(:uid(%config<uid>) :gid(%config<gid>)) };

    # TODO: options to backup deploy path, and to delete build-path?

    my $proc = run <docker network ls --format {{.Name}}>, :out;
    for $compose<networks> (-) $proc.out.slurp(:close).lines {
        run <<docker network create {$_.key}>>;
    }
}

sub up(IO() $compose-path, @containers) {
    my $compose-cmd = <<docker compose -f {$compose-path.resolve}>>;
    for @containers {
        # TODO: optionally recycle with --force-recreate
        run <<$compose-cmd build $_>>;
        run <<$compose-cmd up --no-deps --remove-orphans -d $_>>;
    }
}

sub down(IO() $compose-path, @containers) {
    run <<docker compose -f {$compose-path.resolve} rm -svf {@containers.join(' ')}>>
}

sub validate-containers(*@containers) {
    my $proc = run <docker compose config --services>, :out;
    my @all-containers = $proc.out.slurp(:close).lines;
    if @containers (-) @all-containers { die 'invalid containers specified!'; }
    @containers || @all-containers
}

sub fix-relative-path(IO() $path, IO() $base) {
    ($path ~~ /^\.\.?(\/+.*)?$/ ?? $base.add($path) !! $path).resolve;
}

sub setup-container($container, IO() :$var-path) {
    say "setting up container $container";
    given $container {
        sub add-var(*@args) {
            for %(@args).kv -> $path, $type {
                given $type {
                    when 'd' { mkdir $var-path.add($path); }
                    when 'f' { mkdir $var-path.add($path.IO.parent); $var-path.add($path).open(:a).close; }
                    default { die "unknown var type $type" }
                }
            }
        }
        
        when 'postgres' || 'redis' || 'diun' || 'lldap' {
            add-var <<"$_/data" d>>;
        }
        
        when 'traefik' { add-var <<"$_/acme.json" f>>; }
        when 'rutorrent' { add-var <<"$_/data" d "$_/passwd" d>>; }
        when 'jellyfin' { add-var <<"$_/config" d "$_/cache" d>>; }
        
        # TODO: authelia
        
        # TODO: file-browser
        # for filebrowser proxy auth, database.db must be edited after the container first initializes it.
        # the "header": "Remote-User" pair needs to be added to config.auther in the bolt store, and
        # the "authMethod": "proxy" pair needs to be added to config.settings

        # is it possible to spin up a docker container of filebrowser to generate a database.db with the existing config,
        # then modify in raku to get a working db (add users, fix proxy auth)?

        default { add-var <<"$_" d>> }
    }

    my $uid = %config<uid>;
    my $gid = %config<gid>;

    do given $container {
        sub cadd($service, *@args) { for %(@args).kv -> $key, $item { $service{$key} = |($service{$key} || ()), $item; } }
        sub cset($service, *@args) { for %(@args).kv -> $key, $item { $service{$key} = $item; } }

        when 'mariadb' || 'rutorrent' || 'syncthing' || 'shoko' {
            $container => {
                cadd $_, <<environment "PUID=$uid">>;
                cadd $_, <<environment "PGID=$gid">>;
                $_
            }
        }

        when 'lldap' {
            $container => {
                cadd $_, <<environment "UID=$uid">>;
                cadd $_, <<environment "GID=$gid">>;
                $_
            }
        }
        
        # TODO: add diun labels to all services here
        default {
            $container => {
                cset $_, <<user "$uid:$gid">>;
                $_
            }
        }
    }
};

sub load-config(:$config-file = $default-config-file) {
    use YAMLish;
    %config = load-yaml($config-file.IO.slurp);
}

sub substitute-config-tokens(IO() $path) {
    try {
        my $text = $path.IO.slurp;
        say "substituting tokens in $path";
        for %config.kv -> $key, $value {
            $text ~~ s:g/\<\<\s*$key\s*\>\>/$value/;
        }
        $path.IO.spurt: $text;
    }
}

sub copy-tree(IO() $source, IO() $dest) {
    if $source ~~ :f {
        $source.copy($dest ~~ :d ?? $dest.add($source.basename) !! $dest);
        return;
    }

    if $source ~~ :l {
        symlink $source.resolve, $dest ~~ :d ?? $dest.add($source.basename) !! $dest;
        return;
    }

    if $source ~~ :d and $dest ~~ :d {
        for find $source -> $from {
            my $subpath = $from.resolve.relative($source.parent).IO;
            given $from {
                when :d {
                    my $dir = $dest.add($subpath);
                    mkdir $dir if $dir !~~ :d;
                }
                default { copy-tree $from, $dest.add($subpath.dirname); }
            }
        }
    }
}

multi find(IO() $path, Str:D :$type = 'a', Int :$mindepth = 0) { find $path, 0, :$type, :$mindepth; }
multi find(IO() $path, Int:D $depth, Str:D :$type = 'a', Int:D :$mindepth = 0) {
    |do given $path {
        when :l { $type ~~ 'a'|'l' ?? ($path) !! () }
        when :f { $type ~~ 'a'|'f' ?? ($path) !! () }
        when :d { |($type ~~ 'a'|'d' and $depth > $mindepth ?? ($path) !! ()), |$path.dir>>.&find($depth + 1, :$type, :$mindepth) }
        default { say () }
    }
}

sub check-sudo()
{
    my $proc = run <docker ps>;
    if !$proc {
        if prompt('run with sudo? [y/n] ') eq 'y' {
            say 'run sudo';
        }
    }
}

sub splash($message = '')
{
    my @text = $message.comb.rotor(40, :partial)>>.join;
    $*ERR.say(Q:c"
        ♥
     /\__\__/\     {@text[0] || ''}
    /         \    {@text[1] || ''}
  \(ﾐ  ⌒ ● ⌒  ﾐ)/  {@text[2..*].join}
    ");
}

