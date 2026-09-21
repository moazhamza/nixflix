{ serviceName }:
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nixflix.${serviceName};
  inherit (import ./utils.nix { inherit lib pkgs serviceName; })
    capitalizedName
    mkSecureCurl
    ;

  releaseProfileType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Unique release profile name";
      };
      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "Whether the release profile is enabled";
      };
      required = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Terms that releases must contain";
      };
      ignored = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Terms that releases must not contain";
      };
      indexerId = mkOption {
        type = types.int;
        default = 0;
        description = "Indexer ID, where zero applies to every indexer";
      };
      tags = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Tag names that limit where the release profile applies";
      };
    };
  };

  profilePayload = profile: {
    inherit (profile)
      name
      enabled
      required
      ignored
      indexerId
      ;
    tagNames = profile.tags;
  };
in
{
  options.nixflix.${serviceName}.config.releaseProfiles = mkOption {
    type = types.listOf releaseProfileType;
    default = [ ];
    description = ''
      Release profiles managed through the Arr API. Tags are configured by name
      and created when missing, avoiding host-specific numeric tag IDs.
    '';
  };

  config =
    mkIf
      (
        config.nixflix.enable
        && cfg.enable
        && cfg.config.apiKey != null
        && cfg.config.releaseProfiles != [ ]
      )
      {
        systemd.services."${serviceName}-releaseprofiles" = {
          description = "Configure ${capitalizedName} release profiles via API";
          after = [ "${serviceName}-config.service" ];
          requires = [ "${serviceName}-config.service" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };

          script = ''
            set -eu

            BASE_URL="http://${cfg.config.hostConfig.bindAddress}:${toString cfg.config.hostConfig.port}${cfg.config.hostConfig.urlBase}/api/${cfg.config.apiVersion}"
            PROFILES=${escapeShellArg (builtins.toJSON (map profilePayload cfg.config.releaseProfiles))}

            existing_profiles=$(${
              mkSecureCurl cfg.config.apiKey {
                url = "$BASE_URL/releaseprofile";
                extraArgs = "-Sf";
              }
            })
            echo "$PROFILES" | ${pkgs.jq}/bin/jq -c '.[]' | while IFS= read -r profile; do
              profile_name=$(echo "$profile" | ${pkgs.jq}/bin/jq -r '.name')
              tag_ids='[]'

              echo "$profile" | ${pkgs.jq}/bin/jq -r '.tagNames[]' | while IFS= read -r tag_name; do
                existing_tags=$(${
                  mkSecureCurl cfg.config.apiKey {
                    url = "$BASE_URL/tag";
                    extraArgs = "-Sf";
                  }
                })
                tag_id=$(echo "$existing_tags" | ${pkgs.jq}/bin/jq -r --arg name "$tag_name" '[.[] | select(.label == $name)][0].id // empty')
                if [ -z "$tag_id" ]; then
                  tag_payload=$(${pkgs.jq}/bin/jq -cn --arg label "$tag_name" '{label: $label}')
                  tag_id=$(${
                    mkSecureCurl cfg.config.apiKey {
                      url = "$BASE_URL/tag";
                      method = "POST";
                      headers."Content-Type" = "application/json";
                      data = "$tag_payload";
                      extraArgs = "-Sf";
                    }
                  } | ${pkgs.jq}/bin/jq -r '.id')
                fi
                tag_ids=$(echo "$tag_ids" | ${pkgs.jq}/bin/jq --argjson id "$tag_id" '. + [$id]')
                printf '%s' "$tag_ids" > "$RUNTIME_DIRECTORY/tag-ids"
              done

              if [ -f "$RUNTIME_DIRECTORY/tag-ids" ]; then
                tag_ids=$(cat "$RUNTIME_DIRECTORY/tag-ids")
                rm "$RUNTIME_DIRECTORY/tag-ids"
              fi

              payload=$(echo "$profile" | ${pkgs.jq}/bin/jq --argjson tags "$tag_ids" 'del(.tagNames) + {tags: $tags}')
              profile_id=$(echo "$existing_profiles" | ${pkgs.jq}/bin/jq -r --arg name "$profile_name" '[.[] | select(.name == $name)][0].id // empty')

              if [ -n "$profile_id" ]; then
                payload=$(echo "$payload" | ${pkgs.jq}/bin/jq --argjson id "$profile_id" '. + {id: $id}')
                ${
                  mkSecureCurl cfg.config.apiKey {
                    url = "$BASE_URL/releaseprofile/$profile_id";
                    method = "PUT";
                    headers."Content-Type" = "application/json";
                    data = "$payload";
                    extraArgs = "-Sf";
                  }
                } >/dev/null
              else
                ${
                  mkSecureCurl cfg.config.apiKey {
                    url = "$BASE_URL/releaseprofile";
                    method = "POST";
                    headers."Content-Type" = "application/json";
                    data = "$payload";
                    extraArgs = "-Sf";
                  }
                } >/dev/null
              fi

              echo "Configured release profile: $profile_name"
            done
          '';

          serviceConfig.RuntimeDirectory = "${serviceName}-releaseprofiles";
        };
      };
}
