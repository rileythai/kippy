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

! kipp.f90 -- Kippenhahn rendering library on top of giza
!
! Renders a Kippenhahn diagram from any input loaded by load_convection
! (KEPLER .cnv, MESA profiles, .kipp streams, MONASH seq)
module kipp

   use, intrinsic :: iso_fortran_env, only: output_unit
   use iso_c_binding, only: c_int
   use typedef, only: int32, real64
   use convdata, only: data, fieldlayer, &
                       FIELD_NBINS, nfields, field_names, &
                       field_vmin, field_vmax, field_vpos, field_log, &
                       RADIATIVE, NCONVTYPES
   use mesaload, only: load_convection, kipp_axis_units
   use units, only: unit_id, UNAME, UDIM, UFAC, DIM_TIME, DIM_MASS, DIM_LENGTH
   use cmaps, only: CMAP_NAMES, NCMAPS
   use kipp_state, only: kstate_t, st, nmodels, xedge
   use coords, only: build_axes, kipp_autoscale, set_time_unit, yscale, xtrans, ytrans2, &
                     inv_x, inv_y, mbound, coord_at, bisect_le
   use layers, only: type_of, level_mins, layer_of_cfield, field_of_cfield, field_layer_len, &
                     get_layer, get_field_buf, cache_invalidate
   use axes, only: is_reversed
   use draw, only: kipp_choose_device, kipp_render, kipp_save, kipp_close
   use giza

   implicit none
   private

   interface
      function c_getpid() bind(C, name='getpid') result(pid)
         import :: c_int
         integer(c_int) :: pid
      end function c_getpid
      function c_isatty(fd) bind(C, name='isatty') result(tty)
         import :: c_int
         integer(c_int), value :: fd
         integer(c_int) :: tty
      end function c_isatty
   end interface

   public :: kipp_load, kipp_choose_device, kipp_render, kipp_save, &
             kipp_close, kipp_autoscale, kipp_rebuild, kipp_interact, kipp_wait_input, &
             kipp_action, kipp_window_center, kipp_list_fields, kipp_set_cfield, &
             kipp_list_cmaps, kipp_set_cmap, kipp_set_unit, kstate_t, st, nmodels

   ! characters that are delivered by the giza /xw driver for mouse events
   ! (see giza-shared.h: LEFT/MIDDLE/RIGHT click, scroll wheel, Esc)
   character(len=1), parameter :: K_LCLICK = 'A'
   character(len=1), parameter :: K_MCLICK = 'D'
   character(len=1), parameter :: K_RCLICK = 'X'
   character(len=1), parameter :: K_SCRUP = achar(21)
   character(len=1), parameter :: K_SCRDN = achar(4)
   character(len=1), parameter :: K_SCRLT = achar(12)
   character(len=1), parameter :: K_SCRRT = achar(18)
   character(len=1), parameter :: K_ESC = achar(27)
   character(len=1), parameter :: K_CTRLC = achar(3)

   integer(int32) :: nsnap = 0     ! numbered snapshots from cursor mode

   ! cursor-mode view history for `u`.  limits are kept in seconds (or model
   ! number) and cgs, because the auto time unit rescales st%xmin/xmax
   type :: view_t
      real(real64) :: lim(4)
      logical      :: xauto, yauto
   end type view_t
   type(view_t), allocatable :: views(:)

contains

   !---------------------------------------------------------------------
   subroutine kipp_load(filename)
      character(len=*), intent(in) :: filename
      call load_convection(filename, 1_int32, huge(1_int32))
      nmodels = int(size(data), int32)
      if (nmodels < 2) error stop '[kipp] need at least 2 models'
      if (len_trim(kipp_axis_units(DIM_MASS)) > 0) st%munit = kipp_axis_units(DIM_MASS)
      if (len_trim(kipp_axis_units(DIM_LENGTH)) > 0) st%runit = kipp_axis_units(DIM_LENGTH)
      call cache_invalidate()
      call build_axes()
      call kipp_autoscale()
   end subroutine kipp_load

   !---------------------------------------------------------------------
   ! Interactive cursor mode: block on key presses / mouse clicks in the
   ! /xw window and zoom or pan about the cursor position.  Every action
   ! uses the world coordinates giza reports for the cursor, so keys act
   ! "where the mouse is".  Returns to the caller (the REPL) on q, Esc or
   ! Ctrl-C.
   subroutine kipp_interact()
      real(real64) :: x, y
      character(len=1) :: ch
      integer :: ierr
      logical :: done

      if (.not. st%interactive) then
         print '(a)', '[kipp] cursor mode needs an interactive /xw window'
         return
      end if
      if (st%devid <= 0) call kipp_render()
      if (st%devid <= 0) return
      if (.not. giza_device_has_cursor()) then
         print '(a)', '[kipp] device has no cursor'
         return
      end if

      call cursor_help()
      do
         x = 0.d0; y = 0.d0; ch = ' '
         ierr = giza_get_key_press(x, y, ch)
         if (ierr /= 0) exit
         call kipp_action(ch, x, y, done)
         if (done) exit
      end do
   end subroutine kipp_interact

   ! Block at the REPL prompt until stdin has input (0), the plot window is
   ! clicked (1) or its close button is pressed, now or in cursor mode (-1).
   ! Only watches a terminal: gfortran buffers piped stdin, so poll could
   ! miss lines it has already read.
   integer function kipp_wait_input()
      kipp_wait_input = 0
      if (.not. st%interactive .or. st%devid <= 0) return
      if (c_isatty(0_c_int) == 0) return
      flush (output_unit)
      call giza_select_device(st%devid)
      kipp_wait_input = giza_wait_fd_or_click(0_c_int)
   end function kipp_wait_input

   ! One cursor-mode action: key ch acting at world position (x, y), in
   ! the window coordinates giza reports (log10 space on a log axis).
   ! done is set when ch asks to leave cursor mode.  Shared by the
   ! interactive loop and the scripted REPL `key` command (KIPP_SCRIPT).
   subroutine kipp_action(ch, x, y, done)
      character(len=1), intent(in) :: ch
      real(real64), intent(in) :: x, y
      logical, intent(out) :: done
      real(real64) :: xa, ya, x2, y2
      character(len=1) :: ch2
      character(len=80) :: snap
      character(len=512) :: cmd
      integer :: ierr, exitstat, cmdstat, tmpunit
      type(view_t) :: old, new

      done = .false.
      xa = x; ya = y
      if (.not. allocated(views)) allocate (views(0))
      old = view_now()
      select case (ch)
      case ('q', K_ESC, K_CTRLC)               ! back to the REPL
         done = .true.
      case (K_LCLICK)                          ! drag-rectangle zoom
         x2 = xa; y2 = ya; ch2 = ' '
         ierr = giza_band(giza_band_rectangle, 0, xa, ya, x2, y2, ch2)
         if (ierr == 0 .and. ch2 /= K_ESC .and. ch2 /= K_CTRLC .and. ch2 /= 'q') then
            call set_xrange_w(xa, x2)
            call set_yrange_w(ya, y2)
            call kipp_render()
         end if
      case ('x')                               ! select an x range
         x2 = xa; y2 = ya; ch2 = ' '
         ierr = giza_band(giza_band_vertlines, 0, xa, ya, x2, y2, ch2)
         if (ierr == 0 .and. ch2 /= K_ESC .and. ch2 /= K_CTRLC .and. ch2 /= 'q') then
            call set_xrange_w(xa, x2)
            call kipp_render()
         end if
      case ('y')                               ! select a y range
         x2 = xa; y2 = ya; ch2 = ' '
         ierr = giza_band(giza_band_horzlines, 0, xa, ya, x2, y2, ch2)
         if (ierr == 0 .and. ch2 /= K_ESC .and. ch2 /= K_CTRLC .and. ch2 /= 'q') then
            call set_yrange_w(ya, y2)
            call kipp_render()
         end if
      case (K_SCRUP, 'z', '+')                 ! zoom in about cursor
         call zoom_at(xa, ya, 0.5d0); call kipp_render()
      case (K_SCRDN, K_RCLICK, 'Z', '-')       ! zoom out about cursor
         call zoom_at(xa, ya, 2.0d0); call kipp_render()
      case (K_SCRLT, 'h')
         call pan_frac(-0.25d0, 0.d0); call kipp_render()
      case (K_SCRRT, 'l')
         call pan_frac(0.25d0, 0.d0); call kipp_render()
      case ('j')
         call pan_frac(0.d0, -0.25d0); call kipp_render()
      case ('k')
         call pan_frac(0.d0, 0.25d0); call kipp_render()
      case (K_MCLICK, 'c')                     ! centre view on cursor
         call center_at(xa, ya); call kipp_render()
      case ('r', 'a', '0')                     ! reset to full view
         st%xauto = .true.; st%yauto = .true.
         call kipp_autoscale(); call kipp_render()
      case ('s')                               ! numbered png snapshot
         nsnap = nsnap + 1
         write (snap, '(a,a,i4.4)') trim(st%prefix), '_', nsnap
         call kipp_save(trim(snap))
      case ('p')                               ! copy png to clipboard
         write (snap, '(a,i0,a)') '/tmp/kippy-', c_getpid(), '-clip'
         call kipp_save(trim(snap))
         ! the forked clipboard owner must not hold our stdout/stderr: if
         ! those are a pipe it dies when the pipe closes and the copy is lost.
         ! macos pbcopy only takes text, so the png goes to NSPasteboard via jxa
         cmd = "{ wl-copy --type image/png < "//trim(snap)//".png || "// &
               'osascript -l JavaScript -e ''ObjC.import("AppKit"); '// &
               'var pb = $.NSPasteboard.generalPasteboard; pb.clearContents; '// &
               'if (!pb.setDataForType($.NSData.dataWithContentsOfFile("'//trim(snap)//'.png"), '// &
               '$.NSPasteboardTypePNG)) throw "copy failed"'' || '// &
               "xclip -selection clipboard -t image/png -i "//trim(snap)//".png; } "// &
               ">/dev/null 2>&1"
         exitstat = 1
         cmdstat = 1
         call execute_command_line(trim(cmd), wait=.true., exitstat=exitstat, cmdstat=cmdstat)
         if (cmdstat == 0 .and. exitstat == 0) then
            print '(a)', '[kipp] copied png to clipboard'
         else
            print '(a)', '[kipp] could not copy png: wl-copy, osascript and xclip missing or failed'
         end if
         open (newunit=tmpunit, file=trim(snap)//'.png', status='old', iostat=ierr)
         if (ierr == 0) close (tmpunit, status='delete')
      case ('S')                               ! numbered pdf snapshot
         nsnap = nsnap + 1
         write (snap, '(a,a,i4.4)') trim(st%prefix), '_', nsnap
         call kipp_save(trim(snap)//'.pdf')
      case ('g')                               ! toggle the cell/time grid
         st%showgrid = .not. st%showgrid; call kipp_render()
      case ('m')                               ! toggle the model-number strip
         st%showmodels = .not. st%showmodels; call kipp_render()
      case ('v')                               ! print the cell under the cursor
         call print_cell(xa, ya)
      case ('u')                               ! back to the previous view
         if (size(views) == 0) then
            print '(a)', '[kipp] no earlier view'
         else
            call set_view(views(size(views)))
            views = views(:size(views) - 1)
            call kipp_render()
         end if
      case ('?')
         call cursor_help()
      case default
         ! ignore anything else (shift-click, unmapped keys)
      end select
      ! compared after the render, so a cancelled selection or a pan stopped
      ! by clamp_view at the data edge records nothing
      new = view_now()
      if (ch /= 'u' .and. any(new%lim /= old%lim)) views = [views, old]
   end subroutine kipp_action

   function view_now() result(v)
      type(view_t) :: v
      real(real64) :: fx
      fx = merge(UFAC(unit_id(st%tunit)), 1.d0, st%xaxis == 'time')
      v%lim = [st%xmin*fx, st%xmax*fx, st%ymin*yscale(), st%ymax*yscale()]
      v%xauto = st%xauto; v%yauto = st%yauto
   end function view_now

   subroutine set_view(v)
      type(view_t), intent(in) :: v
      real(real64) :: fx
      fx = merge(UFAC(unit_id(st%tunit)), 1.d0, st%xaxis == 'time')
      st%xmin = v%lim(1)/fx; st%xmax = v%lim(2)/fx
      st%ymin = v%lim(3)/yscale(); st%ymax = v%lim(4)/yscale()
      st%xauto = v%xauto; st%yauto = v%yauto
   end subroutine set_view

   ! centre of the current view in the same window coordinates
   ! kipp_action expects; default position for scripted keys
   subroutine kipp_window_center(cx, cy)
      real(real64), intent(out) :: cx, cy
      cx = 0.5d0*(xtrans(st%xmin) + xtrans(st%xmax))
      cy = 0.5d0*(ytrans2(st%ymin) + ytrans2(st%ymax))
   end subroutine kipp_window_center

   subroutine cursor_help()
      print '(a)', 'cursor mode (keys act at the mouse position in the plot window):'
      print '(a)', '  left-click       drag rectangle zoom     x / y  select x / y range'
      print '(a)', '  scroll / z / Z   zoom in / out           right-click  zoom out'
      print '(a)', '  h j k l          pan left down up right  middle-click / c  centre here'
      print '(a)', '  r                reset to full view      s / S  save png / pdf snapshot'
      print '(a)', '  p                copy png to clipboard   g  toggle cell/time grid'
      print '(a)', '  m                toggle model strip      v  print the cell under the cursor'
      print '(a)', '  u                undo the last view change'
      print '(a)', '  ?                this help               q / Esc / Ctrl-C  back to prompt'
   end subroutine cursor_help

   ! One line describing the model/zone cell at world position (wx, wy): model,
   ! time, zone faces, convection type and the selected colour value as drawn.
   ! Column fields print their bin's value range, since only the bin is stored.
   subroutine print_cell(wx, wy)
      real(real64), intent(in) :: wx, wy
      character(len=14), parameter :: TYPE_NAME(0:NCONVTYPES) = [character(len=14) :: &
         'radiative', 'neutral', 'overshoot', 'semiconvective', 'convective', 'thermohaline']
      character(len=256) :: line
      character(len=96) :: cval
      character(len=12) :: s1, s2, sj
      character(len=11) :: ename
      integer(int32) :: i, j, k, nc, t, layer, f, n, lev, gmin, lmin
      integer(int32), allocatable :: vals(:), idxs(:)
      real(real64) :: yc, a, b
      logical :: logscale

      i = bisect_le(xedge, inv_x(wx))
      j = 0; nc = 0; lev = 0
      if (i >= 1 .and. i <= nmodels) then
         nc = data(i)%ncoord
         yc = inv_y(wy)*yscale()
         if (st%yaxis == 'radius') then
            j = bisect_le(data(i)%rncoord(1:nc), yc)
         else
            j = bisect_le(data(i)%xmcoord(1:nc), yc)
         end if
      end if
      if (j < 1 .or. j >= nc) then
         print '(a)', '[kipp] no cell under the cursor'
         return
      end if

      write (line, '(a,i0)') '[kipp] model ', data(i)%ncyc
      if (st%xaxis /= 'model') then
         write (s1, '(es10.3)') data(i)%timesec/UFAC(unit_id(st%tunit))
         line = trim(line)//'  t = '//trim(adjustl(s1))//' '//trim(st%tunit)
      end if
      write (s1, '(es10.3)') coord_at(i, j)/yscale()
      write (s2, '(es10.3)') coord_at(i, j + 1)/yscale()
      write (sj, '(i0)') j
      line = trim(line)//'  zone '//trim(sj)//': '//trim(adjustl(s1))//' .. '// &
             trim(adjustl(s2))//' '//trim(merge(st%runit, st%munit, st%yaxis == 'radius'))

      ! zone k of the convection run-length list spans [mbound(k-1), mbound(k)]
      t = RADIATIVE
      do k = 1, int(data(i)%nconv, int32)
         if (mbound(i, k) > yc) then
            t = type_of(data(i)%yzip(k))
            exit
         end if
      end do
      line = trim(line)//'  '//trim(TYPE_NAME(t))

      ! the colour value at zone j is the step-function entry starting at or below it
      cval = ''
      layer = layer_of_cfield()
      f = field_of_cfield()
      if (layer >= 0) then
         call get_layer(i, layer, vals, idxs, n)
      else if (f > 0) then
         n = field_layer_len(i, f)
         allocate (vals(n), idxs(n))
         call get_field_buf(i, f, vals, idxs, n)
      end if
      if (allocated(vals)) then
         do k = 1, n
            if (idxs(k) > j) exit
            lev = vals(k)
         end do
      end if
      if (layer >= 0) then
         ename = merge('log eps_nuc', 'log eps_nu ', layer /= 2)
         call level_mins(layer, gmin, lmin)
         lmin = max(lmin, gmin)
         if (lev > 0) then
            write (cval, '(a,a,i0,a)') trim(ename), ' = ', gmin + lev - 1, ' (gain)'
         else if (lev < 0) then
            write (cval, '(a,a,i0,a)') trim(ename), ' = ', lmin - lev - 1, ' (loss)'
         else
            cval = ename(5:)//' below the lowest level'
         end if
      else if (f > 0) then
         logscale = field_log(f) .neqv. st%cflip
         if (logscale) then
            a = log10(field_vpos(f)); b = log10(field_vmax(f))
         else
            a = field_vmin(f); b = field_vmax(f)
         end if
         write (s1, '(es10.3)') a + (b - a)*real(lev - 1, real64)/real(FIELD_NBINS, real64)
         write (s2, '(es10.3)') a + (b - a)*real(lev, real64)/real(FIELD_NBINS, real64)
         write (cval, '(a,a,a,i0,a,i0,a)') trim(merge('log ', '    ', logscale))//' '// &
            trim(field_names(f)), ' = '//trim(adjustl(s1))//' .. '//trim(adjustl(s2)), &
            ' (bin ', lev, '/', FIELD_NBINS, ')'
         cval = adjustl(cval)
      end if
      if (len_trim(cval) > 0) line = trim(line)//'  '//trim(cval)
      print '(a)', trim(line)
   end subroutine print_cell

   ! set the x limits from two world coordinates (any order); degenerate
   ! selections (double-click in place) are ignored
   subroutine set_xrange_w(a, b)
      real(real64), intent(in) :: a, b
      real(real64) :: lo, hi
      lo = min(a, b); hi = max(a, b)
      if (hi <= lo) return
      st%xmin = inv_x(lo); st%xmax = inv_x(hi)
      st%xauto = .false.
   end subroutine set_xrange_w

   subroutine set_yrange_w(a, b)
      real(real64), intent(in) :: a, b
      real(real64) :: lo, hi
      lo = min(a, b); hi = max(a, b)
      if (hi <= lo) return
      st%ymin = inv_y(lo); st%ymax = inv_y(hi)
      st%yauto = .false.
   end subroutine set_yrange_w

   ! rescale both axes about a world-space point: f < 1 zooms in, f > 1
   ! zooms out; the data under the cursor stays put
   subroutine zoom_at(cx, cy, f)
      real(real64), intent(in) :: cx, cy, f
      real(real64) :: a, b
      a = xtrans(st%xmin); b = xtrans(st%xmax)
      st%xmin = inv_x(cx + (a - cx)*f)
      st%xmax = inv_x(cx + (b - cx)*f)
      a = ytrans2(st%ymin); b = ytrans2(st%ymax)
      st%ymin = inv_y(cy + (a - cy)*f)
      st%ymax = inv_y(cy + (b - cy)*f)
      st%xauto = .false.; st%yauto = .false.
   end subroutine zoom_at

   ! shift the view by a fraction of the current world-space span
   subroutine pan_frac(fx, fy)
      real(real64), intent(in) :: fx, fy
      real(real64) :: a, b, d
      if (fx /= 0.d0) then
         a = xtrans(st%xmin); b = xtrans(st%xmax); d = (b - a)*fx
         st%xmin = inv_x(a + d); st%xmax = inv_x(b + d)
         st%xauto = .false.
      end if
      if (fy /= 0.d0) then
         a = ytrans2(st%ymin); b = ytrans2(st%ymax); d = (b - a)*fy
         st%ymin = inv_y(a + d); st%ymax = inv_y(b + d)
         st%yauto = .false.
      end if
   end subroutine pan_frac

   ! pan so the given world-space point becomes the view centre
   subroutine center_at(cx, cy)
      real(real64), intent(in) :: cx, cy
      real(real64) :: a, b, d
      a = xtrans(st%xmin); b = xtrans(st%xmax)
      d = cx - 0.5d0*(a + b)
      st%xmin = inv_x(a + d); st%xmax = inv_x(b + d)
      a = ytrans2(st%ymin); b = ytrans2(st%ymax)
      d = cy - 0.5d0*(a + b)
      st%ymin = inv_y(a + d); st%ymax = inv_y(b + d)
      st%xauto = .false.; st%yauto = .false.
   end subroutine center_at

   ! 1-based position typed as a plain number, or 0 if s is not one
   pure integer(int32) function list_index(s)
      character(len=*), intent(in) :: s
      integer(int32) :: ios
      list_index = 0
      if (len_trim(s) == 0 .or. len_trim(s) > 6) return
      if (verify(trim(s), '0123456789') /= 0) return
      read (s, *, iostat=ios) list_index
      if (ios /= 0) list_index = 0
   end function list_index

   ! select a colormap by name or by its number in kipp_list_cmaps, either
   ! optionally suffixed '_r' to reverse it.  ok is false if unknown.
   subroutine kipp_set_cmap(arg, ok)
      character(len=*), intent(in) :: arg
      logical, intent(out) :: ok
      character(len=len(arg)) :: base
      integer(int32) :: k
      logical :: rev
      rev = is_reversed(arg)
      base = arg(1:len_trim(arg) - merge(2, 0, rev))
      if (base == 'grey') base = 'gray'
      k = findloc(CMAP_NAMES, base, 1)
      if (k == 0) k = list_index(base)
      ok = k >= 1 .and. k <= NCMAPS
      if (ok) st%cmap = trim(CMAP_NAMES(k))//merge('_r', '  ', rev)
   end subroutine kipp_set_cmap

   subroutine kipp_list_cmaps()
      integer(int32) :: k, n
      n = len_trim(st%cmap) - merge(2, 0, is_reversed(st%cmap))
      print '(a)', 'colormaps (cmap <name|number>, append _r to reverse):'
      do k = 1, NCMAPS
         print '(i4,2x,a,a)', k, CMAP_NAMES(k), &
            merge(' (current)', '          ', CMAP_NAMES(k) == st%cmap(1:n))
      end do
   end subroutine kipp_list_cmaps

   !---------------------------------------------------------------------
   ! Rebuild x/y arrays after an axis-type change (called by the REPL).
   ! Cached bands hold mass|radius interfaces, so they must be retraced.
   subroutine kipp_rebuild()
      call cache_invalidate()
      call build_axes()
      ! stored views hold the other axis quantity (time vs model, mass vs radius)
      if (allocated(views)) deallocate (views)
   end subroutine kipp_rebuild

   ! display unit for the axis of the unit's dimension ('solar' and 'cgs' set
   ! mass and radius together), keeping the current view.  a time unit pins
   ! the time axis; 'auto' lets it follow the view span again.  bands index
   ! the x strips and hold cgs y, so nothing is retraced.  ok is false if
   ! unknown.
   subroutine kipp_set_unit(arg, ok)
      character(len=*), intent(in) :: arg
      logical, intent(out) :: ok
      integer(int32) :: k
      ok = .true.
      select case (arg)
      case ('auto')
         st%tauto = .true.
         return
      case ('solar')
         call set_y_units('Msun', 'Rsun')
         return
      case ('cgs')
         call set_y_units('g', 'cm')
         return
      end select
      k = unit_id(arg)
      ok = (k > 0)
      if (.not. ok) return
      select case (UDIM(k))
      case (DIM_TIME)
         st%tauto = .false.
         call set_time_unit(k)
      case (DIM_MASS)
         call set_y_units(UNAME(k), st%runit)
      case (DIM_LENGTH)
         call set_y_units(st%munit, UNAME(k))
      end select
   end subroutine kipp_set_unit

   subroutine set_y_units(munit, runit)
      character(len=*), intent(in) :: munit, runit
      real(real64) :: f
      f = yscale()
      st%munit = munit; st%runit = runit
      f = f/yscale()
      st%ymin = st%ymin*f; st%ymax = st%ymax*f
   end subroutine set_y_units

   ! print the colour fields available for `color <name>`, with the value
   ! range and binning each carries.  the fixed energy/convtype selectors are
   ! always available; the rest come from the loaded source's columns.
   subroutine kipp_list_fields()
      integer(int32) :: k
      character(len=8) :: scale
      print '(a)', 'color selectors (color <name|number>):'
      print '(a)', '   1  convtype   (no colour field, convection hatch only)'
      print '(a)', '   2  epsnuc     nuclear energy layer (log erg/g/s)'
      print '(a)', '   3  neu        neutrino energy layer (log erg/g/s)'
      if (.not. allocated(field_names) .or. nfields < 1) then
         print '(a)', '  (no extra column fields in this source)'
         return
      end if
      print '(a)', '  column fields (min .. max across the run, color -<number> for the other scale):'
      do k = 1, nfields
         scale = merge('log ', 'lin ', field_log(k))
         print '(i4,2x,a16,a,a,es11.3,a,es11.3)', k + 3, field_names(k), &
            '  ', trim(scale), field_vmin(k), ' .. ', field_vmax(k)
      end do
   end subroutine kipp_list_fields

   ! select the colour field by name, or by its number in kipp_list_fields; a
   ! negative number shows that column field in its other (lin/log) scale.
   ! ok is false, with the reason printed, when the selection is refused.
   subroutine kipp_set_cfield(arg, ok)
      character(len=*), intent(in) :: arg
      logical, intent(out) :: ok
      character(len=8), parameter :: FIXED(3) = [character(len=8) :: 'convtype', 'epsnuc', 'neu']
      integer(int32) :: k
      logical :: flip
      flip = .false.
      k = list_index(arg)
      if (k == 0 .and. arg(1:1) == '-') then
         k = list_index(arg(2:))
         flip = k > 0
      end if
      ok = .false.
      if (k > 3 + nfields) then
         print *, 'no color entry ', arg, '   (type color for the list)'
         return
      end if
      if (flip) then
         if (k <= 3) then
            print *, 'no lin/log switch for the fixed selectors 1-3'
            return
         end if
         if (.not. field_log(k - 3) .and. field_vpos(k - 3) > field_vmax(k - 3)) then
            print *, 'no log scale for ', trim(field_names(k - 3)), ': no positive values'
            return
         end if
      end if
      ok = .true.
      st%cflip = flip
      if (k == 0) then
         st%cfield = arg
      else if (k <= 3) then
         st%cfield = FIXED(k)
      else
         st%cfield = field_names(k - 3)
      end if
   end subroutine kipp_set_cfield

end module kipp
