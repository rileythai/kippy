! kippy - Kippenhahn diagram viewer
! Copyright (C) 2026 the kippy authors (see AUTHORS)
!
! This file is part of kippy.
!
! kippy is free software: you can redistribute it and/or modify
! it under the terms of the GNU Lesser General Public License as
! published by the Free Software Foundation, either version 3 of the
! License, or (at your option) any later version.
!
! kippy is distributed in the hope that it will be useful, but WITHOUT
! ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
! FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public
! License for more details.
!
! You should have received a copy of the GNU Lesser General Public
! License along with kippy. If not, see <https://www.gnu.org/licenses/>.

! draw.f90 -- giza devices and scene drawing of the kipp renderer
module draw
   !! giza devices and scene drawing.
   !!
   !! - `kipp_choose_device`, `kipp_render`, `kipp_save` and `kipp_close` open, draw to and close the giza device.
   !! - `draw_scene` draws one frame: colour layer, convection hatch, grid, surface, axes,
   !!   colorbar and model-number strip.
   !! - `draw_band`, `fill_bandset_linked` and `draw_chainset` emit the cached bands and outlines
   !!   of layers.f90 through the polygon scratch `epx`, `epy`.
   !! - `clamp_view` keeps the view limits inside the data.
   !!
   !! The "emit clamp box" bounds every vertex handed to giza, in world coordinates.
   !! It reaches `CLAMP_SPANS` window spans past the view on each side.
   !! The "visible range" `ivis0`..`ivis1` is the models whose strips overlap the view.
   !! `draw_scene` sets both on each render.
   !!
   !! kipp.f90 re-exports the four device routines.
   !! Its cursor keys call `kipp_render` and `kipp_save`.
   !! This module writes the device fields and view limits of `st`, `chs` of kipp_state.f90 and `xoff` of coords.f90.
   !! It holds the per-render state: the clamp box, the visible range, the time offset label and the scratch.

   use iso_c_binding, only: c_int, c_double, c_char, c_null_char
   use typedef, only: int32, real64
   use convdata, only: data, nfields, NEUTRAL, OVERSHOOT, SEMICONV, CONVECTIVE, THERMOHALINE, NCONVTYPES
   use mesaload, only: cnv_loaded
   use units, only: unit_id, axis_offset, auto_time_unit, UFAC
   use kipp_state, only: st, nmodels, xval, xedge, ystar, chs
   use bands, only: band_t, bandset_t, chainset_t
   use coords, only: xoff, set_time_unit, yscale, xtrans, ytrans, ytrans2, inv_x, inv_y, mbound, &
                     bisect_le
   use layers, only: conv_bands, conv_chains, conv_valid, ecache, fcache, layer_of_cfield, &
                     field_of_cfield, fscale, build_conv_cache, build_energy_cache, build_field_cache
   use axes, only: c_giza_round, fit_x_step, tick_labels, labels, draw_colorbar, draw_field_colorbar, &
                   colormap
   use giza

   implicit none
   private

   public :: kipp_choose_device, kipp_render, kipp_save, kipp_close

   interface
      ! giza's own giza_box binding narrows the tick steps to single precision,
      ! which shifts ticks off the labels on deep zooms of large values
      subroutine c_giza_box(xopt, xtick, nxsub, yopt, ytick, nysub) bind(C, name='giza_box')
         !! Draw the frame, ticks and tick labels of the plot box.
         !!
         !! Binds giza's C `giza_box` directly.
         import :: c_char, c_double, c_int
         character(kind=c_char), dimension(*), intent(in) :: xopt
            !! x axis options, a null-terminated `giza_box` option string.
         real(c_double), value :: xtick
            !! Major tick step of the x axis, in world coordinates.
         integer(c_int), value :: nxsub
            !! Number of minor tick intervals per x step.
         character(kind=c_char), dimension(*), intent(in) :: yopt
            !! y axis options, a null-terminated `giza_box` option string.
         real(c_double), value :: ytick
            !! Major tick step of the y axis, in world coordinates.
         integer(c_int), value :: nysub
            !! Number of minor tick intervals per y step.
      end subroutine c_giza_box
   end interface

   integer(int32), parameter :: CI_TYPE(0:NCONVTYPES) = [ &
                                0, &   ! RADIATIVE, not drawn
                                4, &   ! NEUTRAL
                                5, &   ! OVERSHOOT
                                3, &   ! SEMICONV
                                2, &   ! CONVECTIVE
                                6]     ! THERMOHALINE
      !! giza colour index of each convection type, by its code in convdata.f90.

   real(real64), parameter :: PDF_WIDTH = 3.5d0
      !! Page width of a PDF save, in inches.
      !! The page is one column wide, at the golden ratio.
   real(real64), parameter :: PDF_CHS = 2.0d0
      !! Character height of a PDF save.
      !! giza text scales with page height, so this keeps it legible on the small page.

   character(len=64) :: xofftxt = ''
      !! Label of the time offset `xoff` of coords.f90, set on each render by `draw_scene`.

   real(real64), allocatable :: epx(:), epy(:)
      !! Polygon scratch for emitted vertices, grown by `ensure_scratch`.

   real(real64), parameter :: CLAMP_SPANS = 1.0d3
      !! Reach of the emit clamp box past each side of the view, in window spans.
   real(real64) :: exlo = -huge(1.d0), exhi = huge(1.d0)
      !! x limits of the emit clamp box, in world coordinates.
   real(real64) :: eylo = -huge(1.d0), eyhi = huge(1.d0)
      !! y limits of the emit clamp box, in world coordinates.

   integer(int32) :: ivis0 = 1, ivis1 = huge(1_int32)
      !! First and last model of the visible range.
      !! Band emission, the surface line and the grid are clipped to it,
      !! so zoomed redraws scale with the models on screen, not the whole file.

contains

   subroutine kipp_render()
      !! Render the scene to the current device.
      !!
      !! An interactive device (/xw) opens once and gets a new page on each render.
      !! A file device (/png etc) opens fresh on each render so the output file is stable.
      logical :: newdev
      if (st%interactive) then
         newdev = st%devid <= 0
         if (newdev) then
            st%devid = giza_open_device(trim(st%device), trim(st%prefix))
            if (st%devid <= 0) then
               print *, '[kipp] cannot open device ', trim(st%device)
               return
            end if
            ! no "RETURN for next page" prompt between interactive renders
            call giza_stop_prompting()
         end if
         ! compose the frame off-screen and blit it once: without buffering
         ! giza copies the pixmap to the window after every primitive, so
         ! rapid zooms/pans flash the erased page, box and colorbar while
         ! they repaint.  Buffered, the window keeps the previous frame
         ! until giza_end_buffer swaps in the completed new one.
         call giza_begin_buffer()
         if (.not. newdev) call giza_change_page()
         call draw_scene()
         call giza_end_buffer()
      else
         st%devid = giza_open_device(trim(st%device), trim(st%prefix))
         if (st%devid <= 0) then
            print *, '[kipp] cannot open device ', trim(st%device)
            return
         end if
         call draw_scene()
         call giza_close_device()
         st%devid = -1     ! device is closed; nothing persists in file mode
         print '(a)', '[kipp] wrote '//trim(st%prefix)//'.png'
      end if
   end subroutine kipp_render

   subroutine kipp_save(name)
      !! Render once to a named PNG, or a PDF for a `.pdf` name.
      !!
      !! The current device is left as it was.
      !! A PDF page is `PDF_WIDTH` wide, with text at `PDF_CHS`.
      ! Arguments
      character(len=*), intent(in) :: name
         !! Output file name, given `.png` unless it ends in `.png` or `.pdf`.
      character(len=256) :: pfx
      character(len=4) :: ext
      integer :: id, n
      pfx = name
      ext = '.png'
      n = len_trim(pfx)
      if (n > 4) then
         if (pfx(n - 3:n) == '.png' .or. pfx(n - 3:n) == '.pdf') then
            ext = pfx(n - 3:n)
            pfx = pfx(1:n - 4)
         end if
      end if
      if (ext == '.pdf') then
         id = giza_open_device_size('/pdf', trim(pfx), real(PDF_WIDTH), &
                                    real(PDF_WIDTH*2.d0/(1.d0 + sqrt(5.d0))), giza_units_inches)
         chs = PDF_CHS
      else
         id = giza_open_device('/png', trim(pfx))
      end if
      if (id <= 0) then
         print *, '[kipp] cannot open /'//ext(2:)//' for ', trim(pfx)
         chs = 1.d0
         return
      end if
      call draw_scene()
      call giza_close_device()
      chs = 1.d0
      print '(a)', '[kipp] saved '//trim(pfx)//ext
      ! re-select the interactive device if one is open
      if (st%interactive .and. st%devid > 0) call giza_select_device(st%devid)
   end subroutine kipp_save

   subroutine kipp_close()
      !! Close the open device, if any.
      if (st%devid > 0) then
         call giza_select_device(st%devid)
         call giza_close_device()
      end if
      st%devid = -1
   end subroutine kipp_close

   subroutine kipp_choose_device()
      !! Choose the output device from the environment.
      !!
      !! The device is /xw when `$DISPLAY` is set, else a PNG file named by `st%prefix`.
      character(len=256) :: disp
      integer :: ln, status
      call get_environment_variable('DISPLAY', disp, ln, status)
      if (status == 0 .and. ln > 0) then
         st%device = '/xw'
         st%interactive = .true.
         print '(a)', '[kipp] display detected -> interactive /xw window'
      else
         st%device = '/png'
         st%interactive = .false.
         print '(a)', '[kipp] no $DISPLAY -> PNG mode (writes '//trim(st%prefix)//'.png)'
      end if
   end subroutine kipp_choose_device

   subroutine clamp_view()
      !! Keep the view limits inside the data.
      !!
      !! The bounds come from `xedge` and `ystar`, so they follow axis and unit changes.
      !! The clamp works in world coordinates so logarithmic axes clamp correctly.
      !! A pan keeps its span and stops at the data edge.
      !! A view larger than the data snaps to the full range.
      real(real64) :: wlo, whi, w1, w2
      wlo = xtrans(xedge(1)); whi = xtrans(xedge(nmodels + 1))
      w1 = xtrans(st%xmin); w2 = xtrans(st%xmax)
      call clamp1(wlo, whi, w1, w2)
      st%xmin = inv_x(w1); st%xmax = inv_x(w2)
      wlo = ytrans2(ybound_lo()); whi = ytrans2(maxval(ystar)/yscale())
      w1 = ytrans2(st%ymin); w2 = ytrans2(st%ymax)
      call clamp1(wlo, whi, w1, w2)
      st%ymin = inv_y(w1); st%ymax = inv_y(w2)
   end subroutine clamp_view

   pure function ybound_lo() result(v)
      !! Lower y bound of the data, in display units.
      !!
      !! This is the centre (0) on a linear axis.
      !! On a logarithmic axis it is eight decades below the largest outer boundary.
      real(real64) :: v
      if (st%ylog) then
         v = maxval(ystar)/yscale()*1.d-8
      else
         v = 0.d0
      end if
   end function ybound_lo

   pure subroutine clamp1(lo, hi, a, b)
      !! Shift the interval [a, b] into [lo, hi], keeping its span.
      !!
      !! An interval wider than [lo, hi] becomes [lo, hi].
      ! Arguments
      real(real64), intent(in)    :: lo
         !! Lower bound.
      real(real64), intent(in)    :: hi
         !! Upper bound.
      real(real64), intent(inout) :: a
         !! Lower end of the interval.
      real(real64), intent(inout) :: b
         !! Upper end of the interval.
      real(real64) :: d
      if (b - a >= hi - lo) then
         a = lo; b = hi
      else if (a < lo) then
         d = lo - a; a = a + d; b = b + d
      else if (b > hi) then
         d = b - hi; a = a - d; b = b - d
      end if
   end subroutine clamp1

   subroutine set_visible_range()
      !! Set the visible range `ivis0`..`ivis1` from the view.
      !!
      !! These are the first and last model strips overlapping [st%xmin, st%xmax].
      !! `xedge` increases for both x quantities, so a bisection finds the strip at each window edge.
      ivis0 = max(1_int32, min(nmodels, bisect_le(xedge, st%xmin)))
      ivis1 = max(ivis0, min(nmodels, bisect_le(xedge, st%xmax)))
   end subroutine set_visible_range

   subroutine draw_scene()
      !! Draw one frame of the Kippenhahn diagram on the current device.
      !!
      !! The view is clamped to the data, and the time unit and offset follow it, first.
      !! The colour layer, convection hatch, grid and surface are drawn bottom to top.
      !! The axes, colorbar and model-number strip go on top.
      character(len=16) :: xopt, yopt
      character(len=64) :: xlabel, ylabel
      real(real64) :: wx1, wx2, wy1, wy2, vx2, xstep, ystep, xlim
      integer(c_int) :: nxsub, nysub
      integer(int32) :: layer, fidx
      logical :: colored, crowded

      ! define convection colours (match ConvPlot.conv_hatch)
      call giza_set_colour_representation(2, 0.0d0, 0.6d0, 0.0d0)  ! conv  green
      call giza_set_colour_representation(3, 0.9d0, 0.0d0, 0.0d0)  ! semi  red
      call giza_set_colour_representation(4, 0.0d0, 0.8d0, 0.9d0)  ! neut  cyan
      call giza_set_colour_representation(5, 0.9d0, 0.0d0, 0.9d0)  ! osht  magenta
      call giza_set_colour_representation(6, 0.85d0, 0.85d0, 0.0d0)! thal  yellow

      call clamp_view()
      ! log ticks are powers of ten in any unit, so a log axis keeps its unit
      if (st%tauto .and. st%xaxis == 'time' .and. .not. st%xlog) &
         call set_time_unit(auto_time_unit((st%xmax - st%xmin)*UFAC(unit_id(st%tunit))))
      call set_visible_range()
      xoff = 0.d0; xofftxt = ''
      if (st%xoffset .and. st%xaxis == 'time' .and. .not. st%xlog) &
         call axis_offset(st%xmin, st%xmax, unit_id(st%tunit), xoff, xofftxt)
      wx1 = xtrans(st%xmin); wx2 = xtrans(st%xmax)
      wy1 = ytrans2(st%ymin); wy2 = ytrans2(st%ymax)
      ! emit clamp box: coordinates handed to giza are limited to ~1e3
      ! window spans around the view.  cairo stores device coordinates in
      ! 24.8 fixed point, and vertices mapping millions of pixels
      ! off-screen (a region interface far outside a deep zoom) wrap or
      ! degenerate -- fills then vanish or flood the window.  Points that
      ! far out are never visible, so the clamp is exact for the
      ! axis-aligned band/outline geometry and sub-pixel for the surface.
      exlo = wx1 - CLAMP_SPANS*(wx2 - wx1)
      exhi = wx2 + CLAMP_SPANS*(wx2 - wx1)
      eylo = wy1 - CLAMP_SPANS*(wy2 - wy1)
      eyhi = wy2 + CLAMP_SPANS*(wy2 - wy1)

      ! leave the right margin for the colorbar whenever a colour field is
      ! shown (an energy layer, or a generic quantized column)
      layer = layer_of_cfield()
      fidx = 0
      if (layer < 0) fidx = field_of_cfield()
      colored = (layer >= 0 .or. fidx > 0)
      vx2 = merge(0.84d0, 0.95d0, colored)

      ! there used to be a bug in giza_open_device that didnt let it to respect
      ! clipping, so you had to call it twice to absorb the default one.
      ! fixed upstream.
      call giza_set_viewport(0.12d0, vx2, 0.12d0, 0.96d0)
      call giza_set_window(wx1, wx2, wy1, wy2)
      ! erase the full page here, not just at change-page: on /xw a window
      ! resize detected inside giza_set_viewport recreates the pixmap, so
      ! an erase done before this point can be silently discarded and the
      ! frame composites over undefined pixmap memory (ghost artifacts)
      call giza_draw_background()
      call giza_set_character_height(chs)
      call ensure_scratch(4*nmodels + 4)

      ! Convection zones are always drawn (hatched, like convplot's hatch-only
      ! patches).
      !
      ! When `color` selects a nuclear/neutrino energy field, it is
      ! drawn first as solid gain (blue) / loss (magenta) bands, and the
      ! convection hatching is overlaid on top.  A generic column field is
      ! drawn the same way as nested colormap contours.
      if (layer >= 0) then
         call draw_energy(layer)             ! color/energy layer
      else if (fidx > 0) then
         call draw_field(fidx)               ! generic column colour field
      end if
      call draw_convection() ! convective hatch
      call draw_grid(wx1, wx2, wy1, wy2)
      call draw_surface() ! surface of star

      ! axes on top
      call giza_set_colour_index(1)
      call giza_set_line_width(1.d0)
      xopt = 'BCST'; yopt = 'BCST'
      if (st%xlog) xopt = 'BCSTL'
      if (st%ylog) yopt = 'BCSTL'
      ! x labels may reach the page edge, or the colorbar strip when shown
      xlim = merge(0.86d0, 1.d0, colored)
      ! giza_box's automatic step is capped at 0.2 of the range (always
      ! reached on y for kippy's viewport, pixel-checked on png and pdf with
      ! giza's default font); x widens it until its labels fit.  the steps
      ! are passed explicitly so tick_labels' labels land on the ticks.
      ! log axes tick each decade and ignore the step
      xstep = 1.d0; nxsub = 1; ystep = 1.d0; nysub = 1
      if (.not. st%ylog) ystep = c_giza_round(0.2d0*(wy2 - wy1), nysub)
      if (.not. st%xlog) call fit_x_step(wx1, wx2, wy1, wy2, xlim, xstep, nxsub)
      call c_giza_box(trim(xopt)//c_null_char, xstep, nxsub, trim(yopt)//c_null_char, ystep, nysub)
      call tick_labels(wx1, wx2, wy1, wy2, xstep, ystep, xlim, .false., crowded)
      call labels(xlabel, ylabel)
      call giza_label(trim(xlabel), trim(ylabel), '')
      ! matplotlib's spot: right end of the axis, below the tick labels
      if (len_trim(xofftxt) > 0) call giza_annotate('B', 3.0, 1.0, 1.0, trim(xofftxt))

      ! make colorbar + other
      if (colored) then
         if (layer >= 0) then
            call draw_colorbar(layer)
         else
            call draw_field_colorbar(fidx)
         end if
         ! restore the plot viewport/window so the interactive cursor
         ! keeps mapping pixels to data coordinates
         call giza_set_viewport(0.12d0, vx2, 0.12d0, 0.96d0)
         call giza_set_window(wx1, wx2, wy1, wy2)
      end if
      call draw_models(wx1, wx2, wy1, wy2, vx2)
   end subroutine draw_scene

   subroutine draw_models(wx1, wx2, wy1, wy2, vx2)
      !! Draw the model-number strip above the plot.
      !!
      !! Each visible model gets a tick that grows longer and wider with the trailing zeros of its number.
      !! A multiple of five gets an extra half step in length.
      !! The colour cycles through black, red, green and blue with the count of trailing zeros.
      !! Nothing is drawn unless `st%showmodels` is set.
      ! Arguments
      real(real64), intent(in) :: wx1
         !! Left edge of the window, in world coordinates.
      real(real64), intent(in) :: wx2
         !! Right edge of the window, in world coordinates.
      real(real64), intent(in) :: wy1
         !! Bottom edge of the window, in world coordinates.
      real(real64), intent(in) :: wy2
         !! Top edge of the window, in world coordinates.
      real(real64), intent(in) :: vx2
         !! Right edge of the plot viewport, as a fraction of the page width.
      real(real64) :: x(2), y(2), r, g, b
      integer(int32) :: i, val, mag, half, lev

      if (.not. st%showmodels) return

      call giza_set_viewport(0.12d0, vx2, 0.965d0, 0.997d0)
      call giza_set_window(wx1, wx2, 0.d0, 1.d0)
      y(1) = 1.d0
      do i = ivis0, ivis1
         ! mag counts trailing zeroes; half marks the intervening multiple of five
         val = data(i)%ncyc
         mag = 0
         if (val /= 0) then
            do while (mod(val, 10) == 0)
               mag = mag + 1
               val = val/10
            end do
         end if
         half = merge(1_int32, 0_int32, mod(val, 5) == 0)
         lev = 2*mag + half
         select case (mod(mag, 4))
         case (0); r = 0.d0; g = 0.d0; b = 0.d0
         case (1); r = 1.d0; g = 0.d0; b = 0.d0
         case (2); r = 0.d0; g = 0.7d0; b = 0.d0
         case (3); r = 0.d0; g = 0.d0; b = 1.d0
         end select
         call giza_set_colour_representation(7, r, g, b)
         call giza_set_colour_index(7)
         call giza_set_line_width(1.d0 + real(mag, real64))
         x = xtrans(xval(i))
         y(2) = 1.d0 - min(0.9d0, 0.25d0 + 0.13d0*real(lev, real64))
         call giza_line(2, x, y)
      end do

      ! restore the plot viewport so the interactive cursor maps pixels to data coordinates
      call giza_set_viewport(0.12d0, vx2, 0.12d0, 0.96d0)
      call giza_set_window(wx1, wx2, wy1, wy2)
   end subroutine draw_models

   subroutine draw_convection()
      !! Draw the convection zones as hatched regions, the Alex Heger way.
      !!
      !! Each contiguous convective region is drawn from traced bands, not one rectangle per model and zone.
      !! This keeps the renderer fast and the hatch continuous across models.
      !! The bands follow the zone interfaces across models.
      !! All visible bands of a type are filled as one keyholed polygon with the type's hatch.
      !! One fill means giza computes the hatch once, so it stays aligned across band seams.
      !! The outline is stroked separately, in the type colour like convplot's PathPatch edge.
      !! It comes from cached chains along the exact edge of the region.
      !! The internal seams, where the tracer closes and restarts bands at merges and splits, are not part of it.
      !!
      !! Regions are tracked greedily per type.
      !! An interval of model i joins the open band of the previous model that it overlaps in y.
      !! A band with no match is closed, and an interval with no match opens a new band.
      !! Merges and splits close and restart bands.
      !! This is exact enough for the fill and keeps the bookkeeping bounded.
      integer(int32) :: t
      if (.not. conv_valid) call build_conv_cache()
      call giza_set_line_width(1.d0)
      do t = 1, NCONVTYPES
         if (conv_bands(t)%nb == 0) cycle
         call giza_set_colour_index(CI_TYPE(t))
         call set_hatch_for_type(t)
         call fill_bandset_linked(conv_bands(t))
         call draw_chainset(conv_chains(t))
      end do
   end subroutine draw_convection

   subroutine set_hatch_for_type(t)
      !! Set the fill hatch of convection type `t`.
      !!
      !! The hatches match ConvPlot.conv_hatch.
      !! Convective is '/' and thermohaline '\'.
      !! Semiconvective, neutral and overshoot are crossed at different densities.
      ! Arguments
      integer(int32), intent(in) :: t
         !! Convection type code, from convdata.f90.
      select case (t)
      case (CONVECTIVE)                          ! '/'
         call giza_set_fill(3); call giza_set_hatching_style(45.d0, 1.0d0, 0.d0)
      case (THERMOHALINE)                        ! '\'
         call giza_set_fill(3); call giza_set_hatching_style(135.d0, 1.0d0, 0.d0)
      case (OVERSHOOT)                           ! '++'
         call giza_set_fill(4); call giza_set_hatching_style(0.d0, 1.0d0, 0.d0)
      case (NEUTRAL)                             ! 'X'
         call giza_set_fill(4); call giza_set_hatching_style(45.d0, 1.2d0, 0.d0)
      case (SEMICONV)                            ! 'XX'
         call giza_set_fill(4); call giza_set_hatching_style(45.d0, 0.7d0, 0.d0)
      case default
         call giza_set_fill(3); call giza_set_hatching_style(45.d0, 1.0d0, 0.d0)
      end select
   end subroutine set_hatch_for_type

   subroutine draw_bandset(bs)
      !! Fill each band of a bandset as its own polygon.
      ! Arguments
      type(bandset_t), intent(in) :: bs
         !! Bands to fill.
      integer(int32) :: k
      do k = 1, bs%nb
         call draw_band(bs%b(k))
      end do
   end subroutine draw_bandset

   pure function band_y_visible(bd, j0, j1) result(vis)
      !! Test whether band `bd` overlaps the y window over models `j0`..`j1`.
      !!
      !! Bands outside the y window must not be emitted.
      !! Linked into the keyholed fill polygon, their bridges would cross the window.
      !! giza hatches by clip and stroke over the bounding box of the clip extents.
      !! The cairo xlib backend does not confine that to a zero-area keyhole clip,
      !! so hatch lines flood the axes box on /xw.
      ! Arguments
      type(band_t), intent(in) :: bd
         !! Band to test.
      integer(int32), intent(in) :: j0
         !! First model of the visible stretch.
      integer(int32), intent(in) :: j1
         !! Last model of the visible stretch.
      logical :: vis
      integer(int32) :: i, o
      real(real64) :: blo, bhi
      o = 1 - bd%i0
      blo = huge(1.d0); bhi = -huge(1.d0)
      do i = j0, j1
         blo = min(blo, bd%ylo(i + o))
         bhi = max(bhi, bd%yhi(i + o))
      end do
      vis = ytrans(bhi) >= ytrans2(st%ymin) .and. ytrans(blo) <= ytrans2(st%ymax)
   end function band_y_visible

   subroutine draw_band(bd)
      !! Fill one cached band as a single polygon.
      !!
      !! The lower interface is traced left to right as a staircase, then the upper interface right to left.
      !! Only the visible range is emitted.
      !! A band cut by the window edge is closed there, so the polygon side lands on the window boundary.
      ! Arguments
      type(band_t), intent(in) :: bd
         !! Band to fill.
      integer(int32) :: i, n, o, j0, j1
      j0 = max(bd%i0, ivis0)
      j1 = min(bd%i1, ivis1)
      if (j0 > j1) return
      if (.not. band_y_visible(bd, j0, j1)) return
      n = 0
      o = 1 - bd%i0            ! model index -> local band index
      do i = j0, j1
         n = n + 1; epx(n) = clampx(xtrans(xedge(i))); epy(n) = clampy(ytrans(bd%ylo(i + o)))
         n = n + 1; epx(n) = clampx(xtrans(xedge(i + 1))); epy(n) = epy(n - 1)
      end do
      do i = j1, j0, -1
         n = n + 1; epx(n) = clampx(xtrans(xedge(i + 1))); epy(n) = clampy(ytrans(bd%yhi(i + o)))
         n = n + 1; epx(n) = clampx(xtrans(xedge(i))); epy(n) = epy(n - 1)
      end do
      call giza_polygon(n, epx(1:n), epy(1:n))
   end subroutine draw_band

   subroutine fill_bandset_linked(bs)
      !! Fill all visible bands of one type as a single keyholed polygon.
      !!
      !! Band loops are linked by "bridges" between their anchors, the first point of each loop.
      !! Each bridge is walked once out and once back along the same line.
      !! It so encloses no area and stays invisible under cairo's winding fill.
      !! One polygon means one giza fill, so the hatch is computed once and stays aligned across the bands.
      ! Arguments
      type(bandset_t), intent(in) :: bs
         !! Bands of one type.
      integer(int32) :: k, i, n, o, j0, j1, need, nvis
      real(real64), allocatable :: ax(:), ay(:)
      need = 0; nvis = 0
      do k = 1, bs%nb
         j0 = max(bs%b(k)%i0, ivis0); j1 = min(bs%b(k)%i1, ivis1)
         if (j0 > j1) cycle
         if (.not. band_y_visible(bs%b(k), j0, j1)) cycle
         nvis = nvis + 1
         need = need + 4*(j1 - j0 + 1) + 2
      end do
      if (nvis == 0) return
      call ensure_scratch(need + nvis)
      allocate (ax(nvis), ay(nvis))
      n = 0; nvis = 0
      do k = 1, bs%nb
         j0 = max(bs%b(k)%i0, ivis0); j1 = min(bs%b(k)%i1, ivis1)
         if (j0 > j1) cycle
         if (.not. band_y_visible(bs%b(k), j0, j1)) cycle
         o = 1 - bs%b(k)%i0
         nvis = nvis + 1
         ax(nvis) = clampx(xtrans(xedge(j0))); ay(nvis) = clampy(ytrans(bs%b(k)%ylo(j0 + o)))
         ! the jump from the previous band's anchor to this first point
         ! is the bridge out
         do i = j0, j1
            n = n + 1; epx(n) = clampx(xtrans(xedge(i))); epy(n) = clampy(ytrans(bs%b(k)%ylo(i + o)))
            n = n + 1; epx(n) = clampx(xtrans(xedge(i + 1))); epy(n) = epy(n - 1)
         end do
         do i = j1, j0, -1
            n = n + 1; epx(n) = clampx(xtrans(xedge(i + 1))); epy(n) = clampy(ytrans(bs%b(k)%yhi(i + o)))
            n = n + 1; epx(n) = clampx(xtrans(xedge(i))); epy(n) = epy(n - 1)
         end do
         ! close the loop back at this band's anchor
         n = n + 1; epx(n) = ax(nvis); epy(n) = ay(nvis)
      end do
      ! retrace the bridges so each is walked out and back
      do k = nvis - 1, 1, -1
         n = n + 1; epx(n) = ax(k); epy(n) = ay(k)
      end do
      call giza_polygon(n, epx(1:n), epy(1:n))
      deallocate (ax, ay)
   end subroutine fill_bandset_linked

   subroutine draw_chainset(cs)
      !! Stroke the cached region outline of one type.
      !!
      !! Each chain is a polyline along the exact boundary of the region.
      !! Only points on visible strip edges are emitted.
      !! One point of lead-in and lead-out is kept so a cut chain runs through the window edge, where giza clips it.
      ! Arguments
      type(chainset_t), intent(in) :: cs
         !! Outline chains of one type.
      integer(int32) :: k, i, n
      do k = 1, cs%nc
         call ensure_scratch(cs%c(k)%n + 2)
         n = 0
         do i = 1, cs%c(k)%n
            if (cs%c(k)%ei(i) >= ivis0 .and. cs%c(k)%ei(i) <= ivis1 + 1) then
               if (n == 0 .and. i > 1) then
                  n = n + 1
                  epx(n) = clampx(xtrans(xedge(cs%c(k)%ei(i - 1))))
                  epy(n) = clampy(ytrans(cs%c(k)%y(i - 1)))
               end if
               n = n + 1
               epx(n) = clampx(xtrans(xedge(cs%c(k)%ei(i))))
               epy(n) = clampy(ytrans(cs%c(k)%y(i)))
            else if (n > 0) then
               ! one point beyond the window, then break the run
               n = n + 1
               epx(n) = clampx(xtrans(xedge(cs%c(k)%ei(i))))
               epy(n) = clampy(ytrans(cs%c(k)%y(i)))
               if (n >= 2) call giza_line(n, epx(1:n), epy(1:n))
               n = 0
            end if
         end do
         if (n >= 2) call giza_line(n, epx(1:n), epy(1:n))
      end do
   end subroutine draw_chainset

   pure function clampx(v) result(r)
      !! Clamp a world x coordinate to the emit clamp box.
      ! Arguments
      real(real64), intent(in) :: v
         !! World x coordinate.
      real(real64) :: r
      r = min(max(v, exlo), exhi)
   end function clampx

   pure function clampy(v) result(r)
      !! Clamp a world y coordinate to the emit clamp box.
      ! Arguments
      real(real64), intent(in) :: v
         !! World y coordinate.
      real(real64) :: r
      r = min(max(v, eylo), eyhi)
   end function clampy

   subroutine ensure_scratch(need)
      !! Grow the polygon scratch `epx`, `epy` to hold at least `need` points.
      !!
      !! A grown scratch does not keep its old contents.
      ! Arguments
      integer(int32), intent(in) :: need
         !! Number of points needed.
      if (allocated(epx)) then
         if (int(size(epx), int32) >= need) return
         deallocate (epx, epy)
      end if
      allocate (epx(need), epy(need))
   end subroutine ensure_scratch

   subroutine draw_field(f)
      !! Fill a colour field as nested solid bands shaded by the colormap.
      !!
      !! Each contour bin is one bandset.
      !! The coolest bin (1) is drawn first, so hotter bins overpaint inward.
      ! Arguments
      integer(int32), intent(in) :: f
         !! Colour field index, as registered in convdata.f90.
      integer(int32) :: lev
      real(real64) :: t, r, g, b
      if (f < 1 .or. f > nfields) return
      if (.not. fcache(fscale(), f)%valid) call build_field_cache(f)

      call giza_set_fill(1)
      call giza_set_line_width(1.d0)
      associate (fc => fcache(fscale(), f))
         do lev = 1, fc%nlev
            t = (real(lev, real64) - 0.5d0)/real(fc%nlev, real64)
            call colormap(t, r, g, b)
            call giza_set_colour_representation(7, r, g, b)
            call giza_set_colour_index(7)
            call draw_bandset(fc%band(lev))
         end do
      end associate
   end subroutine draw_field

   subroutine draw_energy(layer)
      !! Fill an energy layer as nested solid bands.
      !!
      !! Each integer contour level is one bandset from the cached band tracer, as for the convection zones.
      !! This makes one polygon per contiguous run of models, not per model.
      !! Loss levels shade white to magenta, outermost first.
      !! Gain levels then shade white to blue, nested inward.
      ! Arguments
      integer(int32), intent(in) :: layer
         !! Energy layer index, as described in layers.f90.
      integer(int32) :: lev
      real(real64) :: f
      if (.not. ecache(layer)%valid) call build_energy_cache(layer)

      call giza_set_fill(1)         ! solid bands (convection hatch goes on top)
      call giza_set_line_width(1.d0)
      associate (ec => ecache(layer))
         ! loss (negative) levels: white -> magenta, outermost first
         do lev = 1, ec%lmax
            f = real(lev, real64)/real(max(ec%lmax, 1_int32), real64)
            call giza_set_colour_representation(7, 1.d0, 1.d0 - 0.85d0*f, 1.d0)
            call giza_set_colour_index(7)
            call draw_bandset(ec%loss(lev))
         end do
         ! gain (positive) levels: white -> blue, nested inwards
         do lev = 1, ec%gmax
            f = real(lev, real64)/real(max(ec%gmax, 1_int32), real64)
            call giza_set_colour_representation(7, 1.d0 - 0.85d0*f, 1.d0 - 0.85d0*f, 1.d0)
            call giza_set_colour_index(7)
            call draw_bandset(ec%gain(lev))
         end do
      end associate
   end subroutine draw_energy

   subroutine draw_surface()
      !! Draw the surface line over the visible range.
      !!
      !! One extra model on each side keeps the line crossing the window edge.
      integer(int32) :: i, n, p0, p1
      p0 = max(1_int32, ivis0 - 1)
      p1 = min(nmodels, ivis1 + 1)
      n = 0
      do i = p0, p1
         n = n + 1
         epx(n) = clampx(xtrans(xval(i)))
         epy(n) = clampy(ytrans(ystar(i)))
      end do
      call giza_set_colour_index(1)
      call giza_set_line_width(2.d0)
      call giza_line(n, epx(1:n), epy(1:n))
   end subroutine draw_surface

   subroutine draw_grid(wx1, wx2, wy1, wy2)
      !! Draw the cell and time boundary grid over the visible range.
      !!
      !! Strips narrower than a device pixel merge into the next drawn one, which shows that model's faces.
      !! Faces within a pixel of the last one kept are skipped.
      !! So the cost follows the window size rather than the file.
      !! Nothing is drawn unless `st%showgrid` is set.
      ! Arguments
      real(real64), intent(in) :: wx1
         !! Left edge of the window, in world coordinates.
      real(real64), intent(in) :: wx2
         !! Right edge of the window, in world coordinates.
      real(real64), intent(in) :: wy1
         !! Bottom edge of the window, in world coordinates.
      real(real64), intent(in) :: wy2
         !! Top edge of the window, in world coordinates.
      real(real64) :: px1, px2, py1, py2, dxw, dyw, xa, xb
      integer(int32) :: i
      logical, save :: noted = .false.

      if (.not. st%showgrid) return
      if (cnv_loaded .and. .not. noted) then
         print '(a)', '[kipp] grid: a KEPLER .cnv stores a reduced set of grid points, not every zone'
         noted = .true.
      end if
      call giza_get_viewport(3_c_int, px1, px2, py1, py2)
      dxw = abs(wx2 - wx1)/max(abs(px2 - px1), 1.d0)
      dyw = abs(wy2 - wy1)/max(abs(py2 - py1), 1.d0)
      call giza_set_colour_representation(7, 0.5d0, 0.5d0, 0.5d0)
      call giza_set_colour_index(7)
      call giza_set_line_width(1.d0)
      xa = xtrans(xedge(ivis0))
      call grid_edge(xa, ivis0, ivis0)
      do i = ivis0, ivis1
         xb = xtrans(xedge(i + 1))
         if (xb - xa < dxw .and. i < ivis1) cycle
         if (st%yaxis == 'radius') then
            call grid_strip(xa, xb, data(i)%rncoord, dyw)
         else
            call grid_strip(xa, xb, data(i)%xmcoord, dyw)
         end if
         call grid_edge(xb, i, min(i + 1, nmodels))
         xa = xb
      end do
   end subroutine draw_grid

   subroutine grid_edge(x, i, k)
      !! Draw the time boundary at world `x`, spanning the extent of models `i` and `k`.
      ! Arguments
      real(real64), intent(in) :: x
         !! World x coordinate of the boundary.
      integer(int32), intent(in) :: i
         !! Model on one side of the boundary.
      integer(int32), intent(in) :: k
         !! Model on the other side of the boundary.
      real(real64) :: ex(2), ey(2)
      ex = clampx(x)
      ey(1) = clampy(ytrans(min(mbound(i, 0_int32), mbound(k, 0_int32))))
      ey(2) = clampy(ytrans(max(ystar(i), ystar(k))))
      call giza_line(2, ex, ey)
   end subroutine grid_edge

   subroutine grid_strip(xa, xb, c, dyw)
      !! Draw the cell faces of one strip as a zig-zag polyline.
      !!
      !! The line runs across world x [xa, xb] through the faces in `c` inside the view.
      !! Faces within `dyw` of the last one kept are skipped.
      ! Arguments
      real(real64), intent(in) :: xa
         !! Left edge of the strip, in world coordinates.
      real(real64), intent(in) :: xb
         !! Right edge of the strip, in world coordinates.
      real(real64), intent(in) :: c(:)
         !! Cell faces in cgs, centre to surface.
      real(real64), intent(in) :: dyw
         !! Smallest face spacing drawn, in world y units.
      real(real64) :: y, ylast, xl, xr
      integer(int32) :: j, j0, j1, n

      j0 = max(1_int32, bisect_le(c, min(st%ymin, st%ymax)*yscale()))
      j1 = min(int(size(c), int32), bisect_le(c, max(st%ymin, st%ymax)*yscale()) + 1_int32)
      call ensure_scratch(2*(j1 - j0 + 1))
      xl = clampx(xa); xr = clampx(xb)
      n = 0
      ylast = -huge(1.d0)
      do j = j0, j1
         y = ytrans(c(j))
         if (y - ylast < dyw .and. j < j1) cycle
         ylast = y
         if (mod(n/2, 2) == 0) then
            epx(n + 1) = xl; epx(n + 2) = xr
         else
            epx(n + 1) = xr; epx(n + 2) = xl
         end if
         epy(n + 1:n + 2) = clampy(y)
         n = n + 2
      end do
      if (n >= 2) call giza_line(n, epx(1:n), epy(1:n))
   end subroutine grid_strip

end module draw
