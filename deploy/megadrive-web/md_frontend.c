#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <emscripten/emscripten.h>
#include "libretro/libretro-common/include/libretro.h"

#define DRP_MAX_WIDTH 720
#define DRP_MAX_HEIGHT 576
#define DRP_AUDIO_FRAMES 4096

static uint32_t drp_frame[DRP_MAX_WIDTH * DRP_MAX_HEIGHT];
static int16_t drp_audio[DRP_AUDIO_FRAMES * 2];
static size_t drp_audio_frames;
static unsigned drp_width = 320;
static unsigned drp_height = 224;
static double drp_fps = 60.0;
static double drp_sample_rate = 44100.0;
static enum retro_pixel_format drp_pixel_format = RETRO_PIXEL_FORMAT_0RGB1555;
static uint16_t drp_inputs[2];
static bool drp_initialized;
static bool drp_loaded;

static const uint8_t *drp_rom_data;
static size_t drp_rom_size;
static char drp_rom_path[64] = "/game.md";
static char drp_rom_ext[12] = "md";
static struct retro_game_info_ext drp_game_ext;

/*
 * Cartridge games never enter the Sega CD file path, but the upstream core
 * keeps those references in the same archive. Supplying inert RFILE symbols
 * lets us omit the entire virtual-filesystem layer from the browser runtime.
 */
typedef struct RFILE RFILE;
RFILE *rfopen(const char *path, const char *mode) { (void)path; (void)mode; return NULL; }
int rfclose(RFILE *stream) { (void)stream; return -1; }
int64_t rftell(RFILE *stream) { (void)stream; return -1; }
int64_t rfseek(RFILE *stream, int64_t offset, int origin)
{ (void)stream; (void)offset; (void)origin; return -1; }
int64_t rfread(void *buffer, size_t size, size_t count, RFILE *stream)
{ (void)buffer; (void)size; (void)count; (void)stream; return 0; }
char *rfgets(char *buffer, int count, RFILE *stream)
{ (void)buffer; (void)count; (void)stream; return NULL; }
int rfgetc(RFILE *stream) { (void)stream; return -1; }
int64_t rfwrite(const void *buffer, size_t size, size_t count, RFILE *stream)
{ (void)buffer; (void)size; (void)count; (void)stream; return 0; }
int rfputc(int character, RFILE *stream) { (void)character; (void)stream; return -1; }
int rfprintf(RFILE *stream, const char *format, ...)
{ (void)stream; (void)format; return -1; }
int rferror(RFILE *stream) { (void)stream; return 1; }
int rfeof(RFILE *stream) { (void)stream; return 1; }

/* zlib-compatible CRC32 used by the cartridge SRAM mapper. */
unsigned long crc32(unsigned long crc, const unsigned char *buffer, unsigned int length)
{
   unsigned int index;
   unsigned int bit;
   uint32_t value = (uint32_t)crc ^ 0xffffffffu;
   for (index = 0; index < length; ++index)
   {
      value ^= buffer[index];
      for (bit = 0; bit < 8; ++bit)
         value = (value >> 1) ^ (0xedb88320u & (0u - (value & 1u)));
   }
   return (unsigned long)(value ^ 0xffffffffu);
}

static void drp_log(enum retro_log_level level, const char *format, ...)
{
   va_list args;
   (void)level;
   va_start(args, format);
   vfprintf(stderr, format, args);
   va_end(args);
}

static bool drp_environment(unsigned command, void *data)
{
   static const char *directory = "/";
   static unsigned message_version = 1;
   static float refresh_rate = 60.0f;
   static struct retro_log_callback logger = { drp_log };

   switch (command)
   {
      case RETRO_ENVIRONMENT_GET_CAN_DUPE:
         *(bool *)data = true;
         return true;
      case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
      {
         enum retro_pixel_format requested = *(enum retro_pixel_format *)data;
         if (requested != RETRO_PIXEL_FORMAT_0RGB1555
               && requested != RETRO_PIXEL_FORMAT_RGB565
               && requested != RETRO_PIXEL_FORMAT_XRGB8888)
            return false;
         drp_pixel_format = requested;
         return true;
      }
      case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
      case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
         *(const char **)data = directory;
         return true;
      case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
         *(struct retro_log_callback *)data = logger;
         return true;
      case RETRO_ENVIRONMENT_GET_LANGUAGE:
         *(unsigned *)data = RETRO_LANGUAGE_ENGLISH;
         return true;
      case RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION:
         *(unsigned *)data = message_version;
         return true;
      case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
         return true;
      case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE:
         *(int *)data = 3;
         return true;
      case RETRO_ENVIRONMENT_GET_FASTFORWARDING:
         *(bool *)data = false;
         return true;
      case RETRO_ENVIRONMENT_GET_TARGET_REFRESH_RATE:
         *(float *)data = refresh_rate;
         return true;
      case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
         *(bool *)data = false;
         return true;
      case RETRO_ENVIRONMENT_GET_GAME_INFO_EXT:
         drp_game_ext.full_path = drp_rom_path;
         drp_game_ext.archive_path = NULL;
         drp_game_ext.archive_file = NULL;
         drp_game_ext.dir = "/";
         drp_game_ext.name = "game";
         drp_game_ext.ext = drp_rom_ext;
         drp_game_ext.meta = NULL;
         drp_game_ext.data = drp_rom_data;
         drp_game_ext.size = drp_rom_size;
         drp_game_ext.file_in_archive = false;
         drp_game_ext.persistent_data = true;
         *(const struct retro_game_info_ext **)data = &drp_game_ext;
         return true;
      case RETRO_ENVIRONMENT_SET_GEOMETRY:
      {
         const struct retro_game_geometry *geometry = (const struct retro_game_geometry *)data;
         if (geometry && geometry->base_width && geometry->base_height)
         {
            drp_width = geometry->base_width;
            drp_height = geometry->base_height;
         }
         return true;
      }
      case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
      {
         const struct retro_system_av_info *info = (const struct retro_system_av_info *)data;
         if (info)
         {
            drp_width = info->geometry.base_width;
            drp_height = info->geometry.base_height;
            drp_fps = info->timing.fps;
            drp_sample_rate = info->timing.sample_rate;
            refresh_rate = (float)drp_fps;
         }
         return true;
      }
      case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
      case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
      case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
      case RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE:
      case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
      case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE:
      case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
      case RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY:
      case RETRO_ENVIRONMENT_SET_MESSAGE:
      case RETRO_ENVIRONMENT_SET_MESSAGE_EXT:
         return true;
      default:
         return false;
   }
}

static void drp_video(const void *data, unsigned width, unsigned height, size_t pitch)
{
   unsigned x;
   unsigned y;
   if (!data || width < 1 || height < 1 || width > DRP_MAX_WIDTH || height > DRP_MAX_HEIGHT)
      return;

   drp_width = width;
   drp_height = height;
   for (y = 0; y < height; ++y)
   {
      const uint8_t *source_row = (const uint8_t *)data + (y * pitch);
      uint32_t *target_row = drp_frame + (y * width);
      if (drp_pixel_format == RETRO_PIXEL_FORMAT_XRGB8888)
      {
         const uint32_t *source = (const uint32_t *)source_row;
         for (x = 0; x < width; ++x)
         {
            uint32_t pixel = source[x];
            uint32_t red = (pixel >> 16) & 0xff;
            uint32_t green = (pixel >> 8) & 0xff;
            uint32_t blue = pixel & 0xff;
            target_row[x] = 0xff000000u | (blue << 16) | (green << 8) | red;
         }
      }
      else if (drp_pixel_format == RETRO_PIXEL_FORMAT_RGB565)
      {
         const uint16_t *source = (const uint16_t *)source_row;
         for (x = 0; x < width; ++x)
         {
            uint16_t pixel = source[x];
            uint32_t red = ((pixel >> 11) & 0x1f) * 255 / 31;
            uint32_t green = ((pixel >> 5) & 0x3f) * 255 / 63;
            uint32_t blue = (pixel & 0x1f) * 255 / 31;
            target_row[x] = 0xff000000u | (blue << 16) | (green << 8) | red;
         }
      }
      else
      {
         const uint16_t *source = (const uint16_t *)source_row;
         for (x = 0; x < width; ++x)
         {
            uint16_t pixel = source[x];
            uint32_t red = ((pixel >> 10) & 0x1f) * 255 / 31;
            uint32_t green = ((pixel >> 5) & 0x1f) * 255 / 31;
            uint32_t blue = (pixel & 0x1f) * 255 / 31;
            target_row[x] = 0xff000000u | (blue << 16) | (green << 8) | red;
         }
      }
   }
}

static size_t drp_audio_batch(const int16_t *data, size_t frames)
{
   size_t available = DRP_AUDIO_FRAMES - drp_audio_frames;
   size_t accepted = frames < available ? frames : available;
   if (accepted)
   {
      memcpy(drp_audio + (drp_audio_frames * 2), data, accepted * 2 * sizeof(int16_t));
      drp_audio_frames += accepted;
   }
   return frames;
}

static void drp_input_poll(void)
{
}

static int16_t drp_input_state(unsigned port, unsigned device, unsigned index, unsigned id)
{
   (void)index;
   if (port > 1 || (device & RETRO_DEVICE_MASK) != RETRO_DEVICE_JOYPAD)
      return 0;
   if (id == RETRO_DEVICE_ID_JOYPAD_MASK)
      return (int16_t)drp_inputs[port];
   if (id > RETRO_DEVICE_ID_JOYPAD_R3)
      return 0;
   return (drp_inputs[port] & (1u << id)) ? 1 : 0;
}

EMSCRIPTEN_KEEPALIVE int md_bootstrap(void)
{
   if (drp_initialized)
      return 1;
   retro_set_environment(drp_environment);
   retro_set_video_refresh(drp_video);
   retro_set_audio_sample_batch(drp_audio_batch);
   retro_set_audio_sample(NULL);
   retro_set_input_poll(drp_input_poll);
   retro_set_input_state(drp_input_state);
   retro_init();
   drp_initialized = true;
   return 1;
}

EMSCRIPTEN_KEEPALIVE int md_load(const uint8_t *data, size_t size, const char *extension)
{
   struct retro_game_info info;
   struct retro_system_av_info av;
   size_t extension_length;

   if (!data || size < 512 || !md_bootstrap())
      return 0;
   if (drp_loaded)
   {
      retro_unload_game();
      drp_loaded = false;
   }

   memset(&drp_game_ext, 0, sizeof(drp_game_ext));
   drp_rom_data = data;
   drp_rom_size = size;
   extension_length = extension ? strlen(extension) : 0;
   if (extension_length < 1 || extension_length >= sizeof(drp_rom_ext))
      extension = "md";
   snprintf(drp_rom_ext, sizeof(drp_rom_ext), "%s", extension);
   snprintf(drp_rom_path, sizeof(drp_rom_path), "/game.%s", drp_rom_ext);

   memset(&info, 0, sizeof(info));
   info.path = drp_rom_path;
   info.data = data;
   info.size = size;
   if (!retro_load_game(&info))
      return 0;

   retro_set_controller_port_device(0, RETRO_DEVICE_JOYPAD);
   retro_set_controller_port_device(1, RETRO_DEVICE_JOYPAD);
   retro_get_system_av_info(&av);
   drp_width = av.geometry.base_width;
   drp_height = av.geometry.base_height;
   drp_fps = av.timing.fps;
   drp_sample_rate = av.timing.sample_rate;
   drp_loaded = true;
   return 1;
}

EMSCRIPTEN_KEEPALIVE void md_run_frame(void)
{
   if (!drp_loaded)
      return;
   drp_audio_frames = 0;
   retro_run();
}

EMSCRIPTEN_KEEPALIVE void md_reset(void)
{
   if (drp_loaded)
      retro_reset();
}

EMSCRIPTEN_KEEPALIVE void md_unload(void)
{
   if (drp_loaded)
   {
      retro_unload_game();
      drp_loaded = false;
   }
}

EMSCRIPTEN_KEEPALIVE void md_set_input(unsigned port, uint16_t mask)
{
   if (port < 2)
      drp_inputs[port] = mask;
}

EMSCRIPTEN_KEEPALIVE uintptr_t md_frame_pointer(void) { return (uintptr_t)drp_frame; }
EMSCRIPTEN_KEEPALIVE unsigned md_frame_width(void) { return drp_width; }
EMSCRIPTEN_KEEPALIVE unsigned md_frame_height(void) { return drp_height; }
EMSCRIPTEN_KEEPALIVE uintptr_t md_audio_pointer(void) { return (uintptr_t)drp_audio; }
EMSCRIPTEN_KEEPALIVE unsigned md_audio_frames(void) { return (unsigned)drp_audio_frames; }
EMSCRIPTEN_KEEPALIVE double md_fps(void) { return drp_fps; }
EMSCRIPTEN_KEEPALIVE double md_sample_rate(void) { return drp_sample_rate; }
EMSCRIPTEN_KEEPALIVE uintptr_t md_sram_pointer(void) { return (uintptr_t)retro_get_memory_data(RETRO_MEMORY_SAVE_RAM); }
EMSCRIPTEN_KEEPALIVE unsigned md_sram_size(void) { return (unsigned)retro_get_memory_size(RETRO_MEMORY_SAVE_RAM); }
