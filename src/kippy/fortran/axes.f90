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

! axes.f90 -- tick labels, axis titles and colorbars of the kipp renderer
module axes
   !! Tick labels, axis titles and colorbars.
   !!
   !! - `fit_x_step` widens the linear x tick step until the x labels fit.
   !! - `tick_labels` writes the tick labels of `giza_box`, minus any that would clip.
   !! - `labels` builds the axis titles from the axis quantities and units.
   !! - `draw_colorbar` and `draw_field_colorbar` draw the colorbar of an energy layer
   !!   or a colour field in a strip in the right margin.
   !! - `colormap` gives the colour field's colour at a point of its range.
   !!   `is_reversed` tests a colormap name for the reversing suffix.
   !! - `c_giza_round` rounds a tick step to a "nice" number, 2, 5 or 10 times a power of ten.
   !!
   !! draw.f90 calls the tick, title and colorbar routines from `draw_scene`, and `colormap` for the colour field bands.
   !! kipp.f90 uses `is_reversed` for the colormap selection.
   !! This module holds no state.

   use iso_c_binding, only: c_int, c_double
   use typedef, only: int32, real64
   use convdata, only: FIELD_NBINS, field_names, field_units, field_vmin, field_vmax, &
                       field_vpos, field_log
   use units, only: unit_id, quantity_label, ULABEL
   use cmaps, only: cmap_rgb
   use kipp_state, only: st, chs
   use layers, only: ecache, level_mins, build_energy_cache
   use giza

   implicit none
   private

   public :: c_giza_round, fit_x_step, tick_labels, labels, draw_colorbar, draw_field_colorbar, &
             colormap, is_reversed

   interface
      ! giza's own giza_round binding passes x by reference to a by-value
      ! argument, so nsub never comes back
      function c_giza_round(x, nsub) bind(C, name='giza_round') result(r)
         !! Round `x` to a nice tick step.
         !!
         !! The result is the smallest of 2, 5 or 10 times a power of ten not below |x|, with the sign of x.
         !! Binds giza's C `giza_round` directly.
         import :: c_int, c_double
         real(c_double), value :: x
            !! Value to round.
         integer(c_int), intent(out) :: nsub
            !! Number of minor tick intervals per step: 2 for a step of 2, else 5.
         real(c_double) :: r
      end function c_giza_round
   end interface

   real(real64), parameter :: CB_TICK = 0.8d0
      !! Colorbar tick label height, as a multiple of `chs`.
   real(real64), parameter :: CB_TITLE = 3.5d0
      !! Colorbar title offset from the strip, in tick label heights.

contains

   subroutine fit_x_step(wx1, wx2, wy1, wy2, xlim, step, nsub)
      !! Choose the tick step of a linear x axis.
      !!
      !! The first try is the capped automatic step of `giza_box`, 0.2 of the x range rounded by `c_giza_round`.
      !! The step widens to the next nice step until no x label sits within one character height of the last.
      ! Arguments
      real(real64), intent(in) :: wx1
         !! Left edge of the window, in world coordinates.
      real(real64), intent(in) :: wx2
         !! Right edge of the window, in world coordinates.
      real(real64), intent(in) :: wy1
         !! Bottom edge of the window, in world coordinates.
      real(real64), intent(in) :: wy2
         !! Top edge of the window, in world coordinates.
      real(real64), intent(in) :: xlim
         !! Right limit of the x labels, as a fraction of the page width.
      real(real64), intent(out) :: step
         !! Tick step, in world coordinates.
      integer(c_int), intent(out) :: nsub
         !! Number of minor tick intervals per step.
      logical :: crowded
      step = c_giza_round(0.2d0*(wx2 - wx1), nsub)
      do
         call tick_labels(wx1, wx2, wy1, wy2, step, 1.d0, xlim, .true., crowded)
         if (.not. crowded) exit
         step = c_giza_round(1.001d0*step, nsub)     ! next nice step up
      end do
   end subroutine fit_x_step

   subroutine tick_labels(wx1, wx2, wy1, wy2, xstep, ystep, xlim, dry, crowded)
      !! Write the tick labels of `giza_box` option 'N', minus any that would clip.
      !!
      !! The strings and their placement match `giza_box`.
      !! An x label is dropped past the left page edge or past page fraction `xlim`.
      !! An x label within one character height of the previous one is dropped and sets `crowded`.
      !! A y label is dropped where its text, written along the axis, would run into an x label.
      ! Arguments
      real(real64), intent(in) :: wx1
         !! Left edge of the window, in world coordinates.
      real(real64), intent(in) :: wx2
         !! Right edge of the window, in world coordinates.
      real(real64), intent(in) :: wy1
         !! Bottom edge of the window, in world coordinates.
      real(real64), intent(in) :: wy2
         !! Top edge of the window, in world coordinates.
      real(real64), intent(in) :: xstep
         !! Tick step of the x axis, unused on a logarithmic axis.
      real(real64), intent(in) :: ystep
         !! Tick step of the y axis, unused on a logarithmic axis.
      real(real64), intent(in) :: xlim
         !! Right limit of the x labels, as a fraction of the page width.
      logical, intent(in) :: dry
         !! Only test the x labels for crowding, writing nothing.
      logical, intent(out) :: crowded
         !! An x label was dropped for sitting too close to the previous one.
      integer(int32), parameter :: NBOX = 64
      real(real64) :: px1, px2, py1, py2, nx1, nx2, ny1, ny2, cw, ch, lo, hi, last
      real(real64) :: bx(4, NBOX)        ! kept x label boxes, mm: x1 x2 y1 y2
      integer(int32) :: nb
      character(len=32) :: txt

      call giza_get_viewport(giza_units_mm, px1, px2, py1, py2)
      call giza_get_viewport(giza_units_normalized, nx1, nx2, ny1, ny2)
      call giza_get_character_size(giza_units_mm, cw, ch)
      lo = px1 - nx1*(px2 - px1)/(nx2 - nx1)
      hi = px1 + (xlim - nx1)*(px2 - px1)/(nx2 - nx1)
      crowded = .false.; nb = 0; last = -huge(1.d0)
      call axis(.true., wx1, wx2, xstep, st%xlog)
      if (.not. dry) call axis(.false., wy1, wy2, ystep, st%ylog)
   contains
      subroutine axis(isx, w1, w2, step, logax)
         !! Put the label candidates of one axis, in ascending order.
         !!
         !! A logarithmic axis labels each decade.
         !! It also labels 2 and 5 times each decade when it spans under two decades.
         ! Arguments
         logical, intent(in) :: isx
            !! The x axis, else the y axis.
         real(real64), intent(in) :: w1
            !! Lower edge of the window on this axis, in world coordinates.
         real(real64), intent(in) :: w2
            !! Upper edge of the window on this axis, in world coordinates.
         real(real64), intent(in) :: step
            !! Tick step, unused on a logarithmic axis.
         logical, intent(in) :: logax
            !! The axis is logarithmic.
         integer(int32), parameter :: MANT(2) = [2, 5]
         integer(int32) :: i, k, np, nv
         if (logax) then
            do i = nint(w1) - 1, nint(w2)
               select case (i)
               case (0); txt = '1'
               case (1); txt = '10'
               case default; write (txt, '(a,i0,a)') '10^{', i, '}'
               end select
               call put(isx, (real(i, real64) - w1)/(w2 - w1))
               if (w2 - w1 >= 2.d0) cycle
               do k = 1, 2
                  call giza_format_number(MANT(k), i, giza_number_format_auto, txt)
                  call put(isx, (i + log10(real(MANT(k), real64)) - w1)/(w2 - w1))
               end do
            end do
         else
            np = floor(log10(step)); nv = nint(step/10.d0**np)
            do i = nint(w1/step), nint(w2/step)
               call giza_format_number(i*nv, np, giza_number_format_auto, txt)
               call put(isx, (i*step - w1)/(w2 - w1))
            end do
         end if
      end subroutine axis

      subroutine put(isx, ratio)
         !! Write the label `txt` at one point of an axis, unless it would clip.
         !!
         !! `giza_box` writes x labels 1.2 and y labels 0.7 character heights out from the axis.
         !! Labels are centred on their tick, and y labels run along the axis.
         ! Arguments
         logical, intent(in) :: isx
            !! The x axis, else the y axis.
         real(real64), intent(in) :: ratio
            !! Position along the axis, from 0 at the lower window edge to 1 at the upper.
         real(real64) :: w, h, c, b(4)
         integer(int32) :: k
         if (ratio < 0.d0 .or. ratio > 1.d0) return
         call giza_qtextlen(giza_units_mm, trim(txt), w, h)
         if (isx) then
            c = px1 + ratio*(px2 - px1)
            b = [c - 0.5d0*w, c + 0.5d0*w, py1 - 1.2d0*ch, py1 - 1.2d0*ch + h]
            if (b(1) < last + ch) then
               crowded = .true.
               return
            end if
            if (b(1) < lo .or. b(2) > hi) return
            last = b(2)
            if (nb < NBOX) then
               nb = nb + 1
               bx(:, nb) = b
            end if
            if (.not. dry) call giza_annotate('B', 1.2, real(ratio), 0.5, trim(txt))
         else
            c = py1 + ratio*(py2 - py1)
            b = [px1 - 0.7d0*ch - h, px1 - 0.7d0*ch, c - 0.5d0*w, c + 0.5d0*w]
            do k = 1, nb
               if (b(1) < bx(2, k) .and. bx(1, k) < b(2) .and. &
                   b(3) < bx(4, k) .and. bx(3, k) < b(4)) return
            end do
            call giza_annotate('L', 0.7, real(ratio), 0.5, trim(txt))
         end if
      end subroutine put
   end subroutine tick_labels

   subroutine labels(xlabel, ylabel)
      !! Build the axis titles from the axis quantities and units.
      !!
      !! A logarithmic axis gets a 'log' prefix.
      ! Arguments
      character(len=*), intent(out) :: xlabel
         !! Title of the x axis.
      character(len=*), intent(out) :: ylabel
         !! Title of the y axis.
      if (st%xaxis == 'model') then
         xlabel = 'model number'
      else
         xlabel = 'time ('//trim(ULABEL(unit_id(st%tunit)))//')'
      end if
      if (st%xlog) xlabel = 'log '//trim(xlabel)
      if (st%yaxis == 'radius') then
         ylabel = 'radius ('//trim(ULABEL(unit_id(st%runit)))//')'
      else
         ylabel = 'enclosed mass ('//trim(ULABEL(unit_id(st%munit)))//')'
      end if
      if (st%ylog) ylabel = 'log '//trim(ylabel)
   end subroutine labels

   subroutine draw_colorbar(layer)
      !! Draw the colorbar of an energy layer in the right margin.
      !!
      !! The colorbar is a framed strip of coloured cells.
      !! Gain cells stack from the top, deepest blue for the strongest gain.
      !! Loss cells stack from the bottom, deepest magenta for the strongest loss.
      !! A half-cell gap splits the two.
      !! Each cell's log10 level is written beside it.
      !! A level is nint(log10|eps|), so it names the cell, not a boundary.
      !! GAIN, the title and LOSS run up the outer edge.
      ! Arguments
      integer(int32), intent(in) :: layer
         !! Energy layer, as numbered in layers.f90.
      integer(int32) :: gmax, lmax, gmin, lmin, lev
      real(real64) :: dy, y0, f
      character(len=16) :: txt

      if (.not. ecache(layer)%valid) call build_energy_cache(layer)
      gmax = ecache(layer)%gmax; lmax = ecache(layer)%lmax
      call level_mins(layer, gmin, lmin)
      lmin = max(lmin, gmin)             ! convplot clamps loss min to gain min
      if (gmax + lmax <= 0) return

      dy = 1.d0/(real(gmax + lmax, real64) + merge(0.5d0, 0.d0, gmax > 0 .and. lmax > 0))
      call colorbar_viewport()
      call giza_set_fill(1)

      ! gain cells from the top; colours match draw_energy exactly
      do lev = 1, gmax
         f = real(lev, real64)/real(gmax, real64)
         call giza_set_colour_representation(7, 1.d0 - 0.85d0*f, 1.d0 - 0.85d0*f, 1.d0)
         call giza_set_colour_index(7)
         y0 = 1.d0 - real(gmax - lev + 1, real64)*dy
         call giza_rectangle(0.d0, 1.d0, y0, y0 + dy)
         write (txt, '(i0)') gmin + lev - 1
         call cell_label(y0 + 0.5d0*dy, trim(txt))
      end do
      ! loss cells from the bottom
      do lev = 1, lmax
         f = real(lev, real64)/real(lmax, real64)
         call giza_set_colour_representation(7, 1.d0, 1.d0 - 0.85d0*f, 1.d0)
         call giza_set_colour_index(7)
         y0 = real(lmax - lev, real64)*dy
         call giza_rectangle(0.d0, 1.d0, y0, y0 + dy)
         write (txt, '(i0)') lmin + lev - 1
         call cell_label(y0 + 0.5d0*dy, trim(txt))
      end do

      call giza_set_colour_index(1)
      call giza_set_fill(2)
      if (gmax > 0) call giza_rectangle(0.d0, 1.d0, 1.d0 - real(gmax, real64)*dy, 1.d0)
      if (lmax > 0) call giza_rectangle(0.d0, 1.d0, 0.d0, real(lmax, real64)*dy)
      call giza_set_fill(1)
      if (gmax > 0) call colorbar_title(1.d0, 1.d0, CB_TICK, 'GAIN')
      if (lmax > 0) call colorbar_title(0.d0, 0.d0, CB_TICK, 'LOSS')
      call colorbar_title(0.5d0, 0.5d0, 1.d0, &
         merge('log \ge_{nuc} (erg g^{-1} s^{-1})', 'log \ge_{\gn} (erg g^{-1} s^{-1})', layer /= 2))
      call giza_set_character_height(chs)
   end subroutine draw_colorbar

   subroutine colorbar_viewport()
      !! Set the viewport of the colorbar strip in the right margin.
      !!
      !! The window is the unit square and the character height is the tick label height.
      call giza_set_viewport(0.86d0, 0.88d0, 0.12d0, 0.96d0)
      call giza_set_window(0.d0, 1.d0, 0.d0, 1.d0)
      call giza_set_character_height(CB_TICK*chs)
   end subroutine colorbar_viewport

   subroutine cell_label(y, txt)
      !! Write a horizontal label beside the colorbar strip.
      ! Arguments
      real(real64), intent(in) :: y
         !! Height in the strip window, from 0 to 1.
      character(len=*), intent(in) :: txt
         !! Label text.
      call giza_set_colour_index(1)
      call giza_annotate('RV', 0.5, real(y), 0.0, txt)
   end subroutine cell_label

   subroutine colorbar_title(y, fjust, h, txt)
      !! Write text up the outer side of the colorbar.
      !!
      !! The text clears tick labels of up to about 5 characters.
      ! Arguments
      real(real64), intent(in) :: y
         !! Position along the strip, as a fraction of its height.
      real(real64), intent(in) :: fjust
         !! Justification about `y`: 0 starts the text there, 1 ends it there, 0.5 centres it.
      real(real64), intent(in) :: h
         !! Character height, as a multiple of `chs`.
      character(len=*), intent(in) :: txt
         !! Text to write.
      call giza_set_colour_index(1)
      call giza_set_character_height(h*chs)
      call giza_annotate('R', real(CB_TITLE*CB_TICK/h), real(y), real(fjust), txt)
      call giza_set_character_height(CB_TICK*chs)
   end subroutine colorbar_title

   subroutine draw_field_colorbar(f)
      !! Draw the colorbar of a colour field in the right margin.
      !!
      !! The colorbar is a framed strip of the `FIELD_NBINS` contour colours.
      !! It spans the field's [vmin, vmax] across the whole run.
      !! The round value ticks of `giza_box` sit on its right edge.
      !! The column name runs up the page edge, with 'log' on a logarithmic scale.
      ! Arguments
      integer(int32), intent(in) :: f
         !! Colour field index, as registered in convdata.f90.
      integer(int32) :: lev, p
      real(real64) :: dy, y0, t, r, g, b, vlo, vhi, vmag
      character(len=96) :: title
      character(len=64) :: unit
      character(len=8) :: txt

      call colorbar_viewport()
      call giza_set_fill(1)
      dy = 1.d0/real(FIELD_NBINS, real64)
      do lev = 1, FIELD_NBINS
         t = (real(lev, real64) - 0.5d0)/real(FIELD_NBINS, real64)
         call colormap(t, r, g, b)
         call giza_set_colour_representation(7, r, g, b)
         call giza_set_colour_index(7)
         y0 = real(lev - 1, real64)*dy
         call giza_rectangle(0.d0, 1.d0, y0, y0 + dy)
      end do

      call quantity_label(field_names(f), field_units(f), title, unit)
      vlo = field_vmin(f); vhi = field_vmax(f)
      if (field_log(f) .neqv. st%cflip) then
         vlo = log10(field_vpos(f)); vhi = log10(vhi)
         title = 'log '//trim(title)
      else
         ! move a power of ten into the title so tick labels stay short
         vmag = max(abs(vlo), abs(vhi))
         if (vmag >= 1.d4 .or. (vmag > 0.d0 .and. vmag < 1.d-2)) then
            p = floor(log10(vmag))
            vlo = vlo/10.d0**p; vhi = vhi/10.d0**p
            write (txt, '(i0)') p
            unit = adjustl('10^{'//trim(txt)//'} '//trim(unit))
         end if
      end if
      if (len_trim(unit) > 0) title = trim(title)//' ('//trim(unit)//')'
      call giza_set_colour_index(1)
      call giza_box('BC', 0.0, 0, 'B', 0.0, 0)
      ! a constant field has no value range to tick
      if (vhi > vlo) then
         call giza_set_window(0.d0, 1.d0, vlo, vhi)
         call giza_box('', 0.0, 0, 'CMTIV', 0.0, 0)
      else
         call giza_box('', 0.0, 0, 'C', 0.0, 0)
      end if

      call colorbar_title(0.5d0, 0.5d0, 1.d0, trim(title))
      call giza_set_character_height(chs)
   end subroutine draw_field_colorbar

   pure subroutine colormap(t, r, g, b)
      !! Return the colour of colormap `st%cmap` at `t`.
      !!
      !! A '_r' suffix on the name reverses the colormap.
      ! Arguments
      real(real64), intent(in) :: t
         !! Position in the colormap, from 0 to 1.
      real(real64), intent(out) :: r
         !! Red component, from 0 to 1.
      real(real64), intent(out) :: g
         !! Green component, from 0 to 1.
      real(real64), intent(out) :: b
         !! Blue component, from 0 to 1.
      integer(int32) :: n
      n = len_trim(st%cmap)
      if (is_reversed(st%cmap)) then
         call cmap_rgb(st%cmap(1:n - 2), 1.d0 - t, r, g, b)
      else
         call cmap_rgb(st%cmap(1:n), t, r, g, b)
      end if
   end subroutine colormap

   pure logical function is_reversed(name)
      !! Test whether a colormap name ends in the reversing suffix '_r'.
      ! Arguments
      character(len=*), intent(in) :: name
         !! Colormap name.
      integer(int32) :: n
      n = len_trim(name)
      is_reversed = n > 2
      if (is_reversed) is_reversed = name(n - 1:n) == '_r'
   end function is_reversed

end module axes
