----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- Wrapper for the MiSTer core that runs exclusively in the core's clock domanin
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.video_modes_pkg.all;

entity main is
   generic (
      G_VDNUM                 : natural                     -- amount of virtual drives
   );
   port (
      clk_main_i              : in  std_logic;
      reset_soft_i            : in  std_logic;
      reset_hard_i            : in  std_logic;
      pause_i                 : in  std_logic;
      dim_video_o             : out std_logic;

      -- MiSTer core main clock speed:
      -- Make sure you pass very exact numbers here, because they are used for avoiding clock drift at derived clocks
      clk_main_speed_i        : in  natural;

      -- Video output
      video_ce_o              : out std_logic;
      video_ce_ovl_o          : out std_logic;
      video_red_o             : out std_logic_vector(3 downto 0);
      video_green_o           : out std_logic_vector(3 downto 0);
      video_blue_o            : out std_logic_vector(3 downto 0);
      video_vs_o              : out std_logic;
      video_hs_o              : out std_logic;
      video_hblank_o          : out std_logic;
      video_vblank_o          : out std_logic;

      -- Audio output (Signed PCM)
      audio_left_o            : out signed(15 downto 0);
      audio_right_o           : out signed(15 downto 0);

      -- M2M Keyboard interface
      kb_key_num_i            : in  integer range 0 to 79;    -- cycles through all MEGA65 keys
      kb_key_pressed_n_i      : in  std_logic;                -- low active: debounced feedback: is kb_key_num_i pressed right now?

      -- MEGA65 joysticks and paddles/mouse/potentiometers
      joy_1_up_n_i            : in  std_logic;
      joy_1_down_n_i          : in  std_logic;
      joy_1_left_n_i          : in  std_logic;
      joy_1_right_n_i         : in  std_logic;
      joy_1_fire_n_i          : in  std_logic;

      joy_2_up_n_i            : in  std_logic;
      joy_2_down_n_i          : in  std_logic;
      joy_2_left_n_i          : in  std_logic;
      joy_2_right_n_i         : in  std_logic;
      joy_2_fire_n_i          : in  std_logic;

      pot1_x_i                : in  std_logic_vector(7 downto 0);
      pot1_y_i                : in  std_logic_vector(7 downto 0);
      pot2_x_i                : in  std_logic_vector(7 downto 0);
      pot2_y_i                : in  std_logic_vector(7 downto 0);
      
       -- Dipswitches
      dsw_a_i                 : in  std_logic_vector(7 downto 0);
      dsw_b_i                 : in  std_logic_vector(7 downto 0);

      dn_clk_i                : in  std_logic;
      dn_addr_i               : in  std_logic_vector(18 downto 0);
      dn_data_i               : in  std_logic_vector(7 downto 0);
      dn_wr_i                 : in  std_logic;

      
      osm_control_i      : in  std_logic_vector(255 downto 0)
      
   );
end entity main;

architecture synthesis of main is

signal keyboard_n        : std_logic_vector(79 downto 0);
signal pause_cpu         : std_logic;
signal status            : signed(31 downto 0);
signal flip_screen       : std_logic;
signal flip              : std_logic := '0';
signal forced_scandoubler: std_logic;
signal gamma_bus         : std_logic_vector(21 downto 0);


-- I/O board button press simulation ( active high )
-- b[1]: user button
-- b[0]: osd button

signal buttons           : std_logic_vector(1 downto 0);
signal reset             : std_logic  := reset_hard_i or reset_soft_i;


-- highscore system
signal hs_address       : std_logic_vector(15 downto 0);
signal hs_data_in       : std_logic_vector(7 downto 0);
signal hs_data_out      : std_logic_vector(7 downto 0);
signal hs_write_enable  : std_logic;

signal hs_pause         : std_logic;
signal options          : std_logic_vector(1 downto 0);
signal self_test        : std_logic;

signal ce_6,ce_3,ce_1p5 : std_logic;
signal inv_ena          : std_logic;
signal div              : unsigned(2 downto 0);

constant C_MENU_OSMPAUSE     : natural := 2;
constant C_MENU_OSMDIM       : natural := 3;
constant C_MENU_FLIP         : natural := 9;

-- Game player inputs
constant m65_1             : integer := 56; --Player 1 Start
constant m65_2             : integer := 59; --Player 2 Start
constant m65_5             : integer := 16; --Insert coin 1
constant m65_6             : integer := 19; --Insert coin 2

-- Offer some keyboard controls in addition to Joy 1 Controls
constant m65_up_crsr       : integer := 73; --Player up
constant m65_vert_crsr     : integer := 7;  --Player down
constant m65_left_crsr     : integer := 74; --Player left
constant m65_horz_crsr     : integer := 2;  --Player right
constant m65_space         : integer := 60; --Jump
constant m65_left_shift    : integer := 15; --Fire

-- Pause, credit button & test mode
constant m65_p             : integer := 41; --Pause button
constant m65_s             : integer := 13; --Service 1
constant m65_capslock      : integer := 72; --Service Mode
constant m65_help          : integer := 67; --Help key



-- MiSTer clocks
--.outclk_0(clk_vid),   48Mhz
--.outclk_1(clk_sys),   24Mhz
--.outclk_2(clk_12)     12Mhz

begin
   
    audio_right_o <= audio_left_o;
  
    options(0) <= osm_control_i(C_MENU_OSMPAUSE);
    options(1) <= osm_control_i(C_MENU_OSMDIM);
    flip_screen <= osm_control_i(C_MENU_FLIP);
    
    process(clk_main_i)
    begin
        if rising_edge(clk_main_i) then
            div <= div + 1;
            ce_6 <= not div(0);                                         -- 6809 main cpu
            ce_3 <= (not div(1)) and (not div(0));                      -- Z80 sound cpu
            ce_1p5 <= (not div(2)) and (not div(1)) and (not div(0));   -- YM2203 x 2
        end if;
    end process;
    
    
    i_gng : entity work.jtgng_game
    port map (
    
        rst      => reset,
        soft_rst => reset,
        clk      => clk_main_i, -- 12Mhz main clock
        cen12    => '1',
        cen6     => ce_6,
        cen3     => ce_3,
        cen1p5   => ce_1p5,
        
        start_button(0) => keyboard_n(m65_1),
        start_button(1) => keyboard_n(m65_2),
        coin_input(0)   => keyboard_n(m65_5),
        coin_input(1)   => keyboard_n(m65_6),
        
        red             => video_red_o,
        green           => video_green_o,
        blue            => video_blue_o,
        LHBL            => video_hblank_o,
        LVBL            => video_vblank_o,
        HS              => video_hs_o,
        VS              => video_vs_o,
            
        joystick1(0)    => joy_1_right_n_i and keyboard_n(m65_horz_crsr),
        joystick1(1)    => joy_1_left_n_i and keyboard_n(m65_left_crsr),   
        joystick1(2)    => joy_1_down_n_i and keyboard_n(m65_vert_crsr),
        joystick1(3)    => joy_1_up_n_i and keyboard_n(m65_up_crsr),
        joystick1(4)    => joy_1_fire_n_i and keyboard_n(m65_left_shift),
        joystick1(5)    => keyboard_n(m65_space),
        
        joystick2(0)    => joy_1_right_n_i and keyboard_n(m65_horz_crsr),
        joystick2(1)    => joy_1_left_n_i and keyboard_n(m65_left_crsr),   
        joystick2(2)    => joy_1_down_n_i and keyboard_n(m65_vert_crsr),
        joystick2(3)    => joy_1_up_n_i and keyboard_n(m65_up_crsr),
        joystick2(4)    => joy_1_fire_n_i and keyboard_n(m65_left_shift),
        joystick2(5)    => keyboard_n(m65_space),
        
        romload_clk     =>  dn_clk_i,   -- use clock for M2M rom loading.
	    romload_wr      =>  dn_wr_i,
	    romload_addr    =>  dn_addr_i,
	    romload_data    =>  dn_data_i,
	    
	    enable_char     => '1',
	    enable_scr      => '1',
	    enable_obj      => '1',
	    
	    -- to do later.
	    dip_pause       => '1',
	    dip_inv         => '0',--not inv_ena or not '1', -- FLIP SCREEN - TO DO
	    dip_lives       => "00",
	    dip_level       => "00",
	    dip_bonus       => "00",
	    dip_game_mode   => '1', -- 1 = Game, 0 = Service mode
	    dip_upright     => '0', -- 1 = cocktail, 0 - upright
	    dip_attract_snd => '0', -- ATTRACT SOUND - TO DO ( 0 = SOUND )
	    
	    enable_psg      => '1',
	    enable_fm       => '1',
	    ym_snd          => audio_left_o
	   
     );


    process(clk_main_i)
    variable flg : std_logic_vector(3 downto 0);
    begin
        if rising_edge(clk_main_i) then
            if dn_wr_i = '1' then
                 flg(0) := '1' when (dn_addr_i(1 downto 0) = "00" and dn_data_i = "00100000") else '0';
                 flg(1) := '1' when (dn_addr_i(1 downto 0) = "01" and dn_data_i = "10000011") else '0';
                 flg(2) := '1' when (dn_addr_i(1 downto 0) = "10" and dn_data_i = "00000000") else '0';
                 flg(3) := '1' when (dn_addr_i(1 downto 0) = "00" and dn_data_i = "10000000") else '0';
            end if;
            inv_ena <= flg(0) and flg(1) and flg(2) and flg(3);
        end if;
    end process;
      
   -- @TODO: Keyboard mapping and keyboard behavior
   -- Each core is treating the keyboard in a different way: Some need low-active "matrices", some
   -- might need small high-active keyboard memories, etc. This is why the MiSTer2MEGA65 framework
   -- lets you define literally everything and only provides a minimal abstraction layer to the keyboard.
   -- You need to adjust keyboard.vhd to your needs
   i_keyboard : entity work.keyboard
      port map (
         clk_main_i           => clk_main_i,

         -- Interface to the MEGA65 keyboard
         key_num_i            => kb_key_num_i,
         key_pressed_n_i      => kb_key_pressed_n_i,

         keyboard_n_o          => keyboard_n
      ); -- i_keyboard

end architecture synthesis;

