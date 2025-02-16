#!/usr/bin/env raku
constant $moogle = '
        ♥
     /\__\__/\
    /         \
  \(ﾐ  ⌒ ● ⌒  ﾐ)/
';

constant $default_config_file = 'config.yml';
constant $default_compose_file = 'docker-compose.yml';
constant $default_compose_prod_file = 'docker-compose.production.yml';

my %config;

proto sub MAIN(|) {
    load_config;
    say $moogle;
    return {*};
}

sub GENERATE-USAGE(&main, |capture) {
    say $moogle;
    &*GENERATE-USAGE(&main, |capture)
}
               
multi sub MAIN('deploy',
    *@containers,
) {
    @containers = validate_containers(@containers);
    
    deploy %config<deploy_path><>.IO, @containers;
    up %config<deploy_path><>.IO.add($default_compose_prod_file), @containers;
}

multi sub MAIN('up',
    *@containers,
) {
    up %config<deploy_path><>.IO.add($default_compose_prod_file), validate_containers(@containers);
}

multi sub MAIN('down',
    *@containers,
) {
    down %config<deploy_path><>.IO.add($default_compose_prod_file), validate_containers(@containers);
}

multi sub MAIN('log',
    Str $container
) {
    say 'hi!';
    say find('./etc');
}

sub deploy(IO() $deploy_path, @containers)
{
    use YAMLish;
    
    if $deploy_path !~~ :d { die 'invalid deploy path specified!'; }
    
    # setup containers and build hash of methods to override compose file
    my %setup_container_compose = @containers>>.&setup_container;

    # create data symlink
    my $data_symlink = $deploy_path.add('data');
    unlink $data_symlink if $data_symlink ~~ :l;
    symlink %config<data_path>, $data_symlink;

    # deploy etc directory
    if './etc'.IO ~~ :d {
        copy_tree './etc', $deploy_path;
        find($deploy_path.add('etc'), :type('f'))>>.&substitute_config_tokens;
    }

    # deploy images needed locally
    copy_tree './images', $deploy_path if './images'.IO ~~ :d;
    # generate the production docker compose file
    my $compose = load-yaml($default_compose_file.IO.slurp);
    for $compose<services>.kv -> $key, $service {
        $compose<services>{$key} = %setup_container_compose{$key}($service);
            
        if $compose<services>{$key}<volumes>:exists {
            for $compose<services>{$key}<volumes><> {
                when Str {
                    my $volume = $_.split(':');
                    $_ = (slip fix_relative_path($volume[0]).Str, $volume[1..*]).join(':');
                }
                when Hash {
                    if $_<source>:exists { $_<source> = fix_relative_path($_<source>).Str; }
                };
            }
        }
    }

    # create any missing secrets
    my $secrets_path = $deploy_path.add('secrets');
    mkdir $secrets_path if $secrets_path !~~ :d;
    for $compose<secrets>.kv -> $key, $secret {
        my $secret_path = $secrets_path.add($key);
        if $secret_path !~~ :f {
            $secret_path.spurt: ('a'..'z', 'A'..'Z', 0..9).flat.roll(64).join;
            $secret_path.chmod: 0o600;
        }
        $compose<secrets>{$key}<file> = $secret_path.resolve.Str;
    }

    $deploy_path.add($default_compose_prod_file).spurt: save-yaml($compose);
    find($deploy_path)>>.&{ say "chowning $_ with {%config<uid>}:{%config<gid>}"; $_.chown(:uid(%config<uid>) :gid(%config<gid>)) };

    my $proc = run <docker network ls --format {{.Name}}>, :out;
    for $compose<networks> (-) $proc.out.slurp(:close).lines {
        run <<docker network create {$_.key}>>;
    }
}

sub up(IO() $compose_path, @containers) {
    my $compose_cmd = <<docker compose -f {$compose_path.resolve}>>;
    for @containers {
        # TODO: optionally recycle with --force-recreate
        run <<$compose_cmd build $_>>;
        run <<$compose_cmd up --no-deps --remove-orphans -d $_>>;
    }
}

sub down(IO() $compose_path, @containers) {
    run <<docker compose -f {$compose_path.resolve} rm -svf {@containers.join(' ')}>>
}

sub validate_containers(*@containers) {
    my $proc = run <docker compose config --services>, :out;
    my @all_containers = $proc.out.slurp(:close).lines;
    if @containers (-) @all_containers { die 'invalid containers specified!'; }
    @containers || @all_containers
}

sub fix_relative_path(IO() $path, IO() :$base = %config<deploy_path>.IO --> IO::Path) {
    ($path ~~ /^\.\.?(\/+.*)?$/ ?? $base.add($path) !! $path).resolve;
}

sub setup_container($container) {
    say "setting up container $container";
    given $container {
        sub add_var(*@args, IO() :$varpath = %config<deploy_path>.IO.add('var')) {
            for %(@args).kv -> $path, $type {
                given $type {
                    when 'd' { mkdir $varpath.add($path); }
                    when 'f' { mkdir $varpath.add($path.IO.parent); $varpath.add($path).open(:a).close; }
                    default { die "unknown var type $type" }
                }
            }
        }
        
        when 'postgres' || 'redis' || 'diun' || 'lldap' {
            add_var <<"$_/data" d>>;
        }
        
        when 'traefik' { add_var <<"$_/acme.json" f>>; }
        when 'rutorrent' { add_var <<"$_/data" d "$_/passwd" d>>; }
        when 'jellyfin' { add_var <<"$_/config" d "$_/cache" d>>; }
        
        # TODO: authelia
        
        # TODO: file_browser
        # for filebrowser proxy auth, database.db must be edited after the container first initializes it.
        # the "header": "Remote-User" pair needs to be added to config.auther in the bolt store, and
        # the "authMethod": "proxy" pair needs to be added to config.settings

        # is it possible to spin up a docker container of filebrowser to generate a database.db with the existing config,
        # then modify in raku to get a working db (add users, fix proxy auth)?

        default { add_var <<"$_" d>> }
    }

    my $uid = %config<uid>;
    my $gid = %config<gid>;

    say $container;
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

sub create_vars(*@args, IO() :$varpath = %config<deploy_path>.IO.add('var')) {
    for %(@args).kv -> $path, $type {
        given $type {
            when 'd' { mkdir $varpath.add($path); }
            when 'f' { mkdir $varpath.add($path.IO.parent); $varpath.add($path).open(:a).close; }
            default { die "unknown var type $type" }
        }
    }
}

sub load_config(:$config_file = $default_config_file) {
    use YAMLish;
    %config = load-yaml($config_file.IO.slurp);
}

sub substitute_config_tokens(IO() $path) {
    try {
        my $text = $path.IO.slurp;
        say "substituting tokens in $path";
        for %config.kv -> $key, $value {
            $text ~~ s:g/\<\<\s*$key\s*\>\>/$value/;
        }
        $path.IO.spurt: $text;
    }
}

sub copy_tree(IO() $source, IO() $dest) {
    say "copying $source to $dest";
    if $source ~~ :f and $dest !~~ :d {
        $source.copy($dest);
        return;
    }

    if $source ~~ :f and $dest ~~ :d {
        $source.copy($dest.add($source.basename));
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
                default { copy_tree $from, $dest.add($subpath.dirname); }
            }
        }
    }
}

sub find(IO() $path, Str :$type = 'a') {
    |do given $path {
        when :d { |($type ~~ 'a'|'d' ?? ($path) !! ()), |$path.dir>>.&find(:$type) }
        when :f { $type ~~ 'a'|'f' ?? ($path) !! () }
        when :l { $type ~~ 'a'|'l' ?? ($path) !! () }
        default { say () }
    }
}

sub check_sudo()
{
    my $proc = run <docker ps>;
    if !$proc {
        if prompt('run with sudo? [y/n] ') eq 'y' {
            say 'run sudo';
        }
    }
}
