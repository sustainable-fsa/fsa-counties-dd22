# install.packages("pak")
# pak::pak(
#   c("magrittr",
#     "tidyverse",
#     "sf",
#     "tigris",
#     "rmapshaper")
# )

library(magrittr)
library(tidyverse)
library(sf)
library(tigris)
library(rmapshaper)

## The FSA county definitions
## Create a simplified version
counties <-
  sf::read_sf("/vsizip/FSA_Counties_dd22_NonGeneralized.gdb.zip") %>%
  dplyr::filter(!(FIPSST %in% c("60", "78", "14", "52", "69", "66"))) %>%
  dplyr::select(id = FSA_STCOU) %>%
  {
    # Round-trip to geojson to get rid of strange curved geometry
    tmp <- tempfile(fileext = ".geojson")
    sf::write_sf(., tmp,
                 delete_dsn = TRUE)
    sf::read_sf(tmp)
  } %>%
  sf::st_transform("WGS84") %>%
  rmapshaper::ms_explode(sys = TRUE,
                         sys_mem = 16) %>%
  rmapshaper::ms_dissolve(field = "id",
                          sys = TRUE,
                          sys_mem = 16) %>%
  rmapshaper::ms_simplify(keep = 0.008,
                          sys = TRUE,
                          sys_mem = 16) %>%
  rmapshaper::ms_clip(
    clip =
      tigris::counties(cb = TRUE,
                     resolution = "5m") %>%
      sf::st_transform("WGS84") %>%
      rmapshaper::ms_explode(sys = TRUE,
                             sys_mem = 16) %>%
      rmapshaper::ms_dissolve(sys = TRUE,
                              sys_mem = 16),
    remove_slivers = TRUE,
    sys = TRUE,
    sys_mem = 16
    ) %>%
  sf::st_make_valid() %>%
  rmapshaper::ms_explode(sys = TRUE,
                         sys_mem = 16) %>%
  rmapshaper::ms_dissolve(field = "id",
                          sys = TRUE,
                          sys_mem = 16) %>%
  rmapshaper::ms_explode(sys = TRUE,
                         sys_mem = 16) %>%
  tigris::shift_geometry() %>%
  sf::st_make_valid() %>%
  sf::st_transform("WGS84") %>%
  rmapshaper::ms_explode(sys = TRUE,
                         sys_mem = 16) %>%
  rmapshaper::ms_dissolve(field = "id",
                          sys = TRUE,
                          sys_mem = 16) %>%
  sf::st_cast("MULTIPOLYGON") %>%
  dplyr::arrange(id) %>%
  dplyr::left_join(
    sf::read_sf("/vsizip/FSA_Counties_dd22_NonGeneralized.gdb.zip") %>%
      sf::st_drop_geometry() %>%
      dplyr::select(id = FSA_STCOU,
                    state = STATENAME,
                    county = FSA_Name) %>%
      dplyr::distinct()
  ) %T>%
  sf::write_sf("fsa-counties-dd22.geojson",
               delete_dsn = TRUE)

system(
  "
mapshaper \\
  fsa-counties-dd22.geojson \\
  -clean rewind \\
  -rename-layers counties,states \\
  -dissolve field=state copy-fields='id' + name=states \\
  -each 'id=id.slice(0,2)' target=states \\
  -rename-layers counties,states \\
  -o format=topojson quantization=1e5 fix-geometry id-field='id' bbox target=* fsa-counties-dd22.topojson
"
)

unlink("fsa-counties-dd22.geojson")

# sf::read_sf("fsa-counties-dd22.topojson", layer = "states") %>%
#   mapview::mapview()
