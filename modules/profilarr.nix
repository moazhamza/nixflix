{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  inherit (import ../lib/mkVirtualHosts.nix { inherit lib config; }) mkVirtualHost;
  secrets = import ../lib/secrets { inherit lib; };
  mkSecureCurl = import ../lib/mk-secure-curl.nix { inherit lib pkgs; };

  cfg = config.nixflix.profilarr;
  hostname = "${cfg.subdomain}.${config.nixflix.reverseProxy.domain}";
  containerService = config.virtualisation.oci-containers.containers.profilarr.serviceName;
  apiUrl = "http://127.0.0.1:${toString cfg.port}/api/v1";
  databasePath = "${cfg.dataDir}/data/profilarr.db";
  sqlLiteral = value: "'${replaceStrings [ "'" ] [ "''" ] value}'";

  databaseType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Display name for the Profilarr database.";
      };

      repositoryUrl = mkOption {
        type = types.str;
        description = "Git repository containing the Profilarr database.";
      };

      syncStrategy = mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = "Number of minutes between update checks; zero disables scheduled checks.";
      };

      autoPull = mkOption {
        type = types.bool;
        default = false;
        description = "Whether Profilarr automatically pulls available database updates.";
      };

      conflictStrategy = mkOption {
        type = types.enum [
          "override"
          "align"
          "ask"
        ];
        default = "override";
        description = "How Profilarr handles conflicts with upstream database changes.";
      };
    };
  };

  connectorType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Display name and stable Nix ownership key for the Arr connector.";
      };

      type = mkOption {
        type = types.enum [
          "radarr"
          "sonarr"
        ];
        description = "The Arr application type.";
      };

      url = mkOption {
        type = types.str;
        description = "Internal URL Profilarr uses for API calls.";
      };

      externalUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional browser-facing URL used by Profilarr UI links.";
      };

      apiKey = secrets.mkSecretOption {
        description = "API key Profilarr uses to access this Arr instance.";
      };

      libraryRefreshInterval = mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = "Minutes between library refreshes; zero disables automatic refreshes.";
      };

      sync = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              trigger = mkOption {
                type = types.enum [
                  "manual"
                  "on_pull"
                ];
                default = "on_pull";
              };
              mediaManagement = mkOption {
                type = types.nullOr (
                  types.submodule {
                    options = {
                      database = mkOption { type = types.str; };
                      naming = mkOption { type = types.str; };
                      qualityDefinitions = mkOption { type = types.str; };
                      mediaSettings = mkOption { type = types.str; };
                    };
                  }
                );
                default = null;
              };
              delayProfile = mkOption {
                type = types.nullOr (
                  types.submodule {
                    options = {
                      database = mkOption { type = types.str; };
                      profile = mkOption { type = types.str; };
                    };
                  }
                );
                default = null;
              };
              qualityProfiles = mkOption {
                type = types.listOf (
                  types.submodule {
                    options = {
                      database = mkOption { type = types.str; };
                      profile = mkOption { type = types.str; };
                    };
                  }
                );
                default = [ ];
              };
            };
          }
        );
        default = null;
        description = "Declarative sync selections for this Arr connector.";
      };
    };
  };

  mkConnectorScript = connector: ''
    NAME=${escapeShellArg connector.name}
    TYPE=${escapeShellArg connector.type}
    URL=${escapeShellArg connector.url}
    EXTERNAL_URL=${escapeShellArg (if connector.externalUrl == null then "" else connector.externalUrl)}
    API_KEY=${secrets.toShellValue connector.apiKey}

    if [ -z "$API_KEY" ]; then
      echo "Profilarr connector $NAME has an empty API key" >&2
      exit 1
    fi

    sql_string() {
      printf "'%s'" "$(printf '%s' "$1" | ${pkgs.gnused}/bin/sed "s/'/\\x27\\x27/g")"
    }

    NAME_SQL=$(sql_string "$NAME")
    TYPE_SQL=$(sql_string "$TYPE")
    URL_SQL=$(sql_string "$URL")
    API_KEY_SQL=$(sql_string "$API_KEY")
    EXTERNAL_URL_SQL="NULL"
    if [ -n "$EXTERNAL_URL" ]; then
      EXTERNAL_URL_SQL=$(sql_string "$EXTERNAL_URL")
    fi

    ${pkgs.sqlite}/bin/sqlite3 "$DATABASE" <<SQL
    PRAGMA foreign_keys = ON;
    BEGIN IMMEDIATE;
    INSERT INTO arr_instances (
      name, type, url, external_url, api_key, enabled, library_refresh_interval
    ) VALUES (
      $NAME_SQL, $TYPE_SQL, $URL_SQL, $EXTERNAL_URL_SQL, $API_KEY_SQL,
      1, ${toString connector.libraryRefreshInterval}
    ) ON CONFLICT(name) DO UPDATE SET
      type = excluded.type,
      url = excluded.url,
      external_url = excluded.external_url,
      api_key = excluded.api_key,
      enabled = excluded.enabled,
      library_refresh_interval = excluded.library_refresh_interval,
      updated_at = CURRENT_TIMESTAMP;
    INSERT INTO arr_sync_database_priority (instance_id, database_id, priority)
    SELECT arr.id, database.id, ROW_NUMBER() OVER (ORDER BY database.id)
    FROM arr_instances AS arr
    CROSS JOIN database_instances AS database
    WHERE arr.name = $NAME_SQL
      AND NOT EXISTS (
        SELECT 1
        FROM arr_sync_database_priority AS priority
        WHERE priority.instance_id = arr.id AND priority.database_id = database.id
      );
    COMMIT;
    SQL

    ${optionalString (connector.sync != null) (
      let
        inherit (connector) sync;
        media = sync.mediaManagement;
        delay = sync.delayProfile;
        databaseId = name: "(SELECT id FROM database_instances WHERE name = ${sqlLiteral name})";
        qualityRows = concatMapStringsSep "\n" (profile: ''
          INSERT INTO arr_sync_quality_profiles (instance_id, database_id, profile_name)
          SELECT id, ${databaseId profile.database}, ${sqlLiteral profile.profile}
          FROM arr_instances WHERE name = $NAME_SQL;
        '') sync.qualityProfiles;
      in
      ''
        ${pkgs.sqlite}/bin/sqlite3 "$DATABASE" <<SQL
        PRAGMA foreign_keys = ON;
        BEGIN IMMEDIATE;
        ${optionalString (media != null) ''
          INSERT INTO arr_sync_media_management (
            instance_id, naming_database_id, quality_definitions_database_id,
            media_settings_database_id, trigger, naming_config_name,
            quality_definitions_config_name, media_settings_config_name
          ) SELECT id, ${databaseId media.database}, ${databaseId media.database},
            ${databaseId media.database}, ${sqlLiteral sync.trigger},
            ${sqlLiteral media.naming}, ${sqlLiteral media.qualityDefinitions},
            ${sqlLiteral media.mediaSettings}
          FROM arr_instances WHERE name = $NAME_SQL
          ON CONFLICT(instance_id) DO UPDATE SET
            naming_database_id = excluded.naming_database_id,
            quality_definitions_database_id = excluded.quality_definitions_database_id,
            media_settings_database_id = excluded.media_settings_database_id,
            trigger = excluded.trigger,
            naming_config_name = excluded.naming_config_name,
            quality_definitions_config_name = excluded.quality_definitions_config_name,
            media_settings_config_name = excluded.media_settings_config_name;
        ''}
        ${optionalString (delay != null) ''
          INSERT INTO arr_sync_delay_profiles_config (
            instance_id, trigger, database_id, profile_name
          ) SELECT id, ${sqlLiteral sync.trigger}, ${databaseId delay.database},
            ${sqlLiteral delay.profile}
          FROM arr_instances WHERE name = $NAME_SQL
          ON CONFLICT(instance_id) DO UPDATE SET
            trigger = excluded.trigger,
            database_id = excluded.database_id,
            profile_name = excluded.profile_name;
        ''}
        INSERT INTO arr_sync_quality_profiles_config (instance_id, trigger)
        SELECT id, ${sqlLiteral sync.trigger} FROM arr_instances WHERE name = $NAME_SQL
        ON CONFLICT(instance_id) DO UPDATE SET trigger = excluded.trigger;
        DELETE FROM arr_sync_quality_profiles
        WHERE instance_id = (SELECT id FROM arr_instances WHERE name = $NAME_SQL);
        ${qualityRows}
        COMMIT;
        SQL
      ''
    )}
  '';

  mkDatabaseScript =
    database:
    let
      payload = builtins.toJSON {
        inherit (database) name;
        repository_url = database.repositoryUrl;
        sync_strategy = database.syncStrategy;
        auto_pull = database.autoPull;
        conflict_strategy = database.conflictStrategy;
      };
    in
    ''
      DATABASE_ID=$(echo "$CURRENT_DATABASES" | ${pkgs.jq}/bin/jq -r \
        --arg name ${escapeShellArg database.name} \
        '[.[] | select(.name == $name) | .id][0] // empty')

      if [ -n "$DATABASE_ID" ]; then
        echo "Updating Profilarr database: ${database.name}"
        ${
          mkSecureCurl cfg.apiKey {
            url = "$API_URL/databases/$DATABASE_ID";
            method = "PATCH";
            headers."Content-Type" = "application/json";
            data = payload;
            extraArgs = "-fS";
          }
        } > /dev/null
      else
        echo "Linking Profilarr database: ${database.name}"
        ${
          mkSecureCurl cfg.apiKey {
            url = "$API_URL/databases";
            method = "POST";
            headers."Content-Type" = "application/json";
            data = payload;
            extraArgs = "-fS";
          }
        } > /dev/null
      fi
    '';
in
{
  options.nixflix.profilarr = {
    enable = mkEnableOption "Profilarr configuration manager for Radarr and Sonarr";

    image = mkOption {
      type = types.str;
      default = "ghcr.io/dictionarry-hub/profilarr:2.2.0";
      description = "OCI image used to run Profilarr.";
    };

    apiKey = secrets.mkSecretOption {
      description = ''
        Profilarr API key used by the declarative database setup service.
        The key must contain at least 32 characters.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "profilarr";
      description = "User that owns the Profilarr data directory and runs the app in the container.";
    };

    group = mkOption {
      type = types.str;
      default = "profilarr";
      description = "Group that owns the Profilarr data directory.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "${config.nixflix.stateDir}/profilarr";
      defaultText = literalExpression ''"''${nixflix.stateDir}/profilarr"'';
      description = "Directory containing Profilarr state and its SQLite database.";
    };

    port = mkOption {
      type = types.port;
      default = 6868;
      description = "Host port on which Profilarr listens.";
    };

    timeZone = mkOption {
      type = types.str;
      # time.timeZone is nullOr str, so `or` is not enough: it only guards a
      # missing attribute, not a null value.
      default = if config.time.timeZone != null then config.time.timeZone else "Etc/UTC";
      defaultText = literalExpression ''config.time.timeZone or "Etc/UTC"'';
      example = "America/New_York";
      description = "Time zone Profilarr uses for scheduled jobs.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the Profilarr port in the firewall.";
    };

    subdomain = mkOption {
      type = types.str;
      default = "profilarr";
      description = "Subdomain prefix for reverse proxy routing.";
    };

    reverseProxy.expose = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to expose Profilarr through the reverse proxy.";
    };

    databases = mkOption {
      type = types.listOf databaseType;
      default = [
        {
          name = "Dictionarry";
          repositoryUrl = "https://github.com/Dictionarry-Hub/database";
          syncStrategy = 60;
          autoPull = true;
        }
        {
          name = "trash-pcd";
          repositoryUrl = "https://github.com/Dictionarry-Hub/trash-pcd";
          syncStrategy = 1440;
          autoPull = true;
        }
      ];
      description = "Profilarr databases to link and keep configured.";
    };

    connectors = mkOption {
      type = types.listOf connectorType;
      default = [ ];
      description = ''
        Arr instances managed by Nix. Existing connectors with matching names are updated;
        connectors created outside Nix are left untouched.
      '';
    };
  };

  config = mkIf (config.nixflix.enable && cfg.enable) (mkMerge [
    (mkVirtualHost {
      inherit hostname;
      inherit (cfg.reverseProxy) expose;
      inherit (cfg) port;
      websocketUpgrade = true;
    })
    {
      assertions = optional (!secrets.isSecretRef cfg.apiKey) {
        assertion = stringLength cfg.apiKey >= 32;
        message = "nixflix.profilarr.apiKey must contain at least 32 characters.";
      };

      users.users.${cfg.user} = {
        inherit (cfg) group;
        isSystemUser = true;
        home = cfg.dataDir;
      };

      users.groups.${cfg.group} = { };

      # The container entrypoint runs as root and chowns /config to PUID:PGID
      # before dropping privileges, so the directory has to be owned by the
      # same user the container is told to use. Otherwise systemd-tmpfiles and
      # the entrypoint fight over the owner on every start.
      systemd.tmpfiles.settings."10-profilarr".${cfg.dataDir}.d = {
        mode = "0750";
        inherit (cfg) user group;
      };

      virtualisation.oci-containers.containers.profilarr = {
        inherit (cfg) image;
        ports = [
          "${if config.nixflix.reverseProxy.enable then "127.0.0.1" else "0.0.0.0"}:${toString cfg.port}:6868"
        ];
        volumes = [ "${cfg.dataDir}:/config" ];
        environment = {
          AUTH = "on";
          TZ = cfg.timeZone;
        };
        environmentFiles = [ "/run/profilarr/container.env" ];
      };

      systemd.services.${containerService} = {
        after = [ "nixflix-setup-dirs.service" ] ++ config.nixflix.serviceDependencies;
        requires = [ "nixflix-setup-dirs.service" ] ++ config.nixflix.serviceDependencies;
        preStart = mkBefore ''
          install -d -m 0700 /run/profilarr
          API_KEY=${secrets.toShellValue cfg.apiKey}
          printf 'PROFILARR_API_KEY=%s\n' "$API_KEY" > /run/profilarr/container.env
          # PUID and PGID are resolved at runtime so the module does not have
          # to pin a static uid for the profilarr user.
          printf 'PUID=%s\n' "$(${pkgs.coreutils}/bin/id -u ${escapeShellArg cfg.user})" \
            >> /run/profilarr/container.env
          printf 'PGID=%s\n' "$(${pkgs.coreutils}/bin/id -g ${escapeShellArg cfg.user})" \
            >> /run/profilarr/container.env
          chmod 0600 /run/profilarr/container.env
        '';
      };

      systemd.services.profilarr-databases = {
        description = "Configure Profilarr databases via API";
        after = [ "${containerService}.service" ];
        requires = [ "${containerService}.service" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          set -eu
          API_URL=${escapeShellArg apiUrl}

          ${pkgs.curl}/bin/curl --retry 60 --retry-delay 2 --retry-connrefused \
            -fsS "$API_URL/health" > /dev/null

          CURRENT_DATABASES=$(${
            mkSecureCurl cfg.apiKey {
              url = "$API_URL/databases";
              extraArgs = "-fS";
            }
          })

          ${concatMapStringsSep "\n" mkDatabaseScript cfg.databases}
        '';
      };

      systemd.services.profilarr-connectors = mkIf (cfg.connectors != [ ]) {
        description = "Configure Profilarr Arr connectors";
        after = [
          "${containerService}.service"
          "profilarr-databases.service"
        ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        path = [
          pkgs.coreutils
          pkgs.gnused
          pkgs.systemd
        ];

        script = ''
          set -eu
          DATABASE=${escapeShellArg databasePath}

          systemctl stop ${escapeShellArg "${containerService}.service"}
          trap 'systemctl start ${escapeShellArg "${containerService}.service"}' EXIT

          ${concatMapStringsSep "\n" mkConnectorScript cfg.connectors}
        '';
      };

      networking.firewall.allowedTCPPorts = optional cfg.openFirewall cfg.port;
    }
  ]);
}
