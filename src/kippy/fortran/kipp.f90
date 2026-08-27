! kipp.f90 -- Kippenhahn rendering library on top of giza
!
! Designed to read KEPLER .cnv convection data (via the vendored Fortran reader
! typedef/convdata/convload) and renders a Kippenhahn diagram
module kipp

   use typedef, only: int32, real64
   use convdata, only: data, fieldlayer, &
                       FIELD_NBINS, nfields, field_names, &
                       field_vmin, field_vmax, field_log
   use mesaload, only: load_convection
   use giza

   implicit none
   private

   public :: kipp_load, kipp_choose_device, kipp_render, kipp_save, &
             kipp_close, kipp_autoscale, kipp_rebuild, kipp_interact, &
             kipp_action, kipp_window_center, kipp_list_fields, st, nmodels

   ! physical constants to match keppy.data.physconst.Kepler / YR
   real(real64), parameter :: SOLMASS = 1.9892d33      ! g
   real(real64), parameter :: SOLRAD = 6.9599d10      ! cm
   real(real64), parameter :: YR = 31556952.d0    ! s (Gregorian year)
   real(real64), parameter :: LOGMIN = 1.d-99

   ! convection-type codes (keppy.data.convdata.conv_types):
   !   ' '=0 radiative  'N'=1 neutral  'O'=2 overshoot
   !   'S'=3 semiconv   'C'=4 convective 'T'=5 thermohaline
   ! giza colour indices assigned to each type (0 = radiative, not drawn):
   integer(int32), parameter :: CI_TYPE(0:5) = [0, 4, 5, 3, 2, 6]

   type, public :: kstate_t
      character(len=8)  :: xaxis = 'time'      ! 'time' | 'model'
      character(len=8)  :: yaxis = 'mass'      ! 'mass' | 'radius'
      logical           :: ysolar = .true.     ! Msun/Rsun vs g/cm
      logical           :: xlog = .false.
      logical           :: ylog = .false.
      real(real64)      :: xmin = 0, xmax = 0, ymin = 0, ymax = 0
      logical           :: xauto = .true., yauto = .true.
      character(len=32) :: cfield = 'epsnuc'   ! convtype | epsnuc | neu | any field name
      character(len=64) :: device = '/xw'      ! ?
      character(len=64) :: prefix = 'convview'
      logical           :: interactive = .true.
      integer           :: devid = -1
   end type kstate_t

   type(kstate_t) :: st

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

   integer(int32) :: nsnap = 0     ! numbered snapshots from cursor mode

   integer(int32) :: nmodels = 0
   real(real64), allocatable :: xval(:)    ! x coordinate per model (yr or ncyc)
   real(real64), allocatable :: xedge(:)   ! model strip edges (nmodels+1)
   real(real64), allocatable :: ystar(:)   ! outer mass/radius per model (cgs)

   ! i think this is really sick so read below

   ! Greedy band tracer datatype
   !
   ! Turns per-model (ylo,yhi) intervals of one
   ! "feature" (a convection type, or one energy contour level) into a small
   ! number of bands spanning contiguous runs of models.
   ! Closed bands are stored into a bandset_t cache.
   type :: tracer_t
      integer(int32) :: maxbands = 0
      integer(int32), allocatable :: i0(:), i1(:)     ! first/last model of band
      logical, allocatable :: opn(:), ext(:)   ! open? / extended this step?
      real(real64), allocatable :: ylo(:, :), yhi(:, :) ! (band, model) interfaces
   end type tracer_t

   ! One traced band in data coordinates: model range on x, cgs mass/radius
   ! interfaces on y.  View-independent -- zoom/pan/units only change the
   ! transforms applied at emit time, so bands are cached across renders and
   ! a redraw only pays the polygon fill cost.
   type :: band_t
      integer(int32) :: i0 = 0, i1 = 0
      real(real64), allocatable :: ylo(:), yhi(:)   ! (i1-i0+1) interfaces
   end type band_t

   type :: bandset_t
      integer(int32) :: nb = 0
      type(band_t), allocatable :: b(:)
   end type bandset_t

   ! One outline polyline along a region boundary, in data coordinates:
   ! x is a strip-edge index into xedge, y a cgs mass/radius coordinate.
   type :: chain_t
      integer(int32) :: n = 0
      integer(int32), allocatable :: ei(:)
      real(real64), allocatable :: y(:)
   end type chain_t

   type :: chainset_t
      integer(int32) :: nc = 0
      type(chain_t), allocatable :: c(:)
   end type chainset_t

   ! per-layer energy-band cache (gain/loss bands per contour level)
   type :: ecache_t
      logical :: valid = .false.
      integer(int32) :: gmax = 0, lmax = 0
      type(bandset_t), allocatable :: gain(:), loss(:)
   end type ecache_t

   ! per-field band cache: one nested bandset per contour bin (bin 1 covers
   ! the whole star, higher bins nest inward), filled on first use of a
   ! `color <field>` selection
   type :: fcache_t
      logical :: valid = .false.
      integer(int32) :: nlev = 0
      type(bandset_t), allocatable :: band(:)
   end type fcache_t

   ! cached traced bands, invalidated on file load and axis rebuild;
   ! energy bands cached per layer so `color` switches do not retrace
   type(bandset_t) :: conv_bands(5)
   type(chainset_t):: conv_chains(5)   ! exact region outlines per conv type
   logical         :: conv_valid = .false.
   type(ecache_t)  :: ecache(0:2)
   type(fcache_t), allocatable :: fcache(:)   ! one per registered colour field

   real(real64), allocatable :: epx(:), epy(:)   ! polygon emit scratch

   ! emit clamp box in transformed coordinates (set per render by
   ! draw_scene; see the comment there for why it exists)
   real(real64), parameter :: CLAMP_SPANS = 1.0d3
   real(real64) :: exlo = -huge(1.d0), exhi = huge(1.d0)
   real(real64) :: eylo = -huge(1.d0), eyhi = huge(1.d0)

   ! visible model range for the current render (set by draw_scene); band
   ! emission and the surface line are clipped to it so zoomed redraws
   ! scale with the models on screen, not the whole file
   integer(int32) :: ivis0 = 1, ivis1 = huge(1_int32)

contains

   !---------------------------------------------------------------------
   subroutine kipp_load(filename)
      character(len=*), intent(in) :: filename
      call load_convection(filename, 1_int32, huge(1_int32))
      nmodels = int(size(data), int32)
      if (nmodels < 2) error stop '[kipp] need at least 2 models'
      call cache_invalidate()
      call build_axes()
      call kipp_autoscale()
   end subroutine kipp_load

   !---------------------------------------------------------------------
   ! Build per-model x coordinate, strip edges, and the outer boundary.
   subroutine build_axes()
      integer(int32) :: i
      if (allocated(xval)) deallocate (xval)
      if (allocated(xedge)) deallocate (xedge)
      if (allocated(ystar)) deallocate (ystar)
      if (allocated(epx)) deallocate (epx, epy)
      allocate (xval(nmodels), xedge(nmodels + 1), ystar(nmodels))
      allocate (epx(4*nmodels + 4), epy(4*nmodels + 4))
      do i = 1, nmodels
         if (st%xaxis == 'model') then
            xval(i) = real(data(i)%ncyc, real64)
         else
            xval(i) = data(i)%timesec/YR
         end if
         if (st%yaxis == 'radius') then
            ystar(i) = data(i)%rncoord(data(i)%ncoord)
         else
            ystar(i) = data(i)%xmcoord(data(i)%ncoord)
         end if
      end do
      ! strip edges = midpoints between successive model x-values
      xedge(1) = xval(1) - 0.5d0*(xval(2) - xval(1))
      do i = 2, nmodels
         xedge(i) = 0.5d0*(xval(i - 1) + xval(i))
      end do
      xedge(nmodels + 1) = xval(nmodels) + 0.5d0*(xval(nmodels) - xval(nmodels - 1))
   end subroutine build_axes

   !---------------------------------------------------------------------
   ! Reset auto limits from the data (called on load and `reset`).
   subroutine kipp_autoscale()
      if (st%xauto) then
         st%xmin = xedge(1)
         st%xmax = xedge(nmodels + 1)
      end if
      if (st%yauto) then
         st%ymin = 0.d0
         st%ymax = maxval(ystar)/yscale()
         if (st%ylog) st%ymin = st%ymax*1.d-4
      end if
   end subroutine kipp_autoscale

   !---------------------------------------------------------------------
   pure function yscale() result(s)
      real(real64) :: s
      if (st%yaxis == 'radius') then
         s = merge(SOLRAD, 1.d0, st%ysolar)
      else
         s = merge(SOLMASS, 1.d0, st%ysolar)
      end if
   end function yscale

   pure function xtrans(x) result(p)
      real(real64), intent(in) :: x
      real(real64) :: p
      if (st%xlog) then
         p = log10(max(x, LOGMIN))
      else
         p = x
      end if
   end function xtrans

   ! transform a cgs mass/radius coordinate into plotted units
   pure function ytrans(c) result(p)
      real(real64), intent(in) :: c
      real(real64) :: p
      p = c/yscale()
      if (st%ylog) p = log10(max(p, LOGMIN))
   end function ytrans

   !---------------------------------------------------------------------
   ! mass/radius coordinate at convection boundary k (0..nconv) of model i.
   ! Mirrors ConvRecord mc/rc reconstruction (convdata.py:1608).
   pure function mbound(i, k) result(c)
      integer(int32), intent(in) :: i, k
      real(real64) :: c
      integer(int32) :: ic, nc
      nc = data(i)%ncoord
      if (st%yaxis == 'radius') then
         if (k == 0) then
            c = data(i)%rncoord(1)
         else
            ic = data(i)%iconv(k)
            c = (0.5d0*(data(i)%rncoord(ic)**3 + &
                        data(i)%rncoord(min(ic + 1, nc))**3))**(1.d0/3.d0)
         end if
      else
         if (k == 0) then
            c = data(i)%xmcoord(1)
         else
            ic = data(i)%iconv(k)
            c = 0.5d0*(data(i)%xmcoord(ic) + data(i)%xmcoord(min(ic + 1, nc)))
         end if
      end if
   end function mbound

   pure function type_of(ch) result(t)
      character(len=1), intent(in) :: ch
      integer(int32) :: t
      select case (ch)
      case ('N'); t = 1
      case ('O'); t = 2
      case ('S'); t = 3
      case ('C'); t = 4
      case ('T'); t = 5
      case default; t = 0
      end select
   end function type_of

   !---------------------------------------------------------------------
   ! Device lifecycle: interactive (/xw) opens once and pages; file mode
   ! (/png etc) opens fresh each render so the output file is stable.
   subroutine kipp_render()
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

   ! One-off render to a named PNG, independent of the current device.
   subroutine kipp_save(name)
      character(len=*), intent(in) :: name
      character(len=64) :: pfx
      integer :: id, n
      pfx = name
      n = len_trim(pfx)
      if (n > 4) then
         if (pfx(n - 3:n) == '.png') pfx = pfx(1:n - 4)
      end if
      id = giza_open_device('/png', trim(pfx))
      if (id <= 0) then
         print *, '[kipp] cannot open /png for ', trim(pfx)
         return
      end if
      call draw_scene()
      call giza_close_device()
      print '(a)', '[kipp] saved '//trim(pfx)//'.png'
      ! re-select the interactive device if one is open
      if (st%interactive .and. st%devid > 0) call giza_select_device(st%devid)
   end subroutine kipp_save

   subroutine kipp_close()
      if (st%devid > 0) then
         call giza_select_device(st%devid)
         call giza_close_device()
      end if
      st%devid = -1
   end subroutine kipp_close

   !---------------------------------------------------------------------
   ! Choose the output device: /xw if $DISPLAY is set, else a PNG file.
   subroutine kipp_choose_device()
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

   !---------------------------------------------------------------------
   ! Interactive cursor mode: block on key presses / mouse clicks in the
   ! /xw window and zoom or pan about the cursor position.  Every action
   ! uses the world coordinates giza reports for the cursor, so keys act
   ! "where the mouse is".  Returns to the caller (the REPL) on q or Esc.
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
      integer :: ierr

      done = .false.
      xa = x; ya = y
      select case (ch)
      case ('q', K_ESC)                        ! back to the REPL
         done = .true.
      case (K_LCLICK)                          ! drag-rectangle zoom
         x2 = xa; y2 = ya; ch2 = ' '
         ierr = giza_band(giza_band_rectangle, 0, xa, ya, x2, y2, ch2)
         if (ierr == 0 .and. ch2 /= K_ESC .and. ch2 /= 'q') then
            call set_xrange_w(xa, x2)
            call set_yrange_w(ya, y2)
            call kipp_render()
         end if
      case ('x')                               ! select an x range
         x2 = xa; y2 = ya; ch2 = ' '
         ierr = giza_band(giza_band_vertlines, 0, xa, ya, x2, y2, ch2)
         if (ierr == 0 .and. ch2 /= K_ESC .and. ch2 /= 'q') then
            call set_xrange_w(xa, x2)
            call kipp_render()
         end if
      case ('y')                               ! select a y range
         x2 = xa; y2 = ya; ch2 = ' '
         ierr = giza_band(giza_band_horzlines, 0, xa, ya, x2, y2, ch2)
         if (ierr == 0 .and. ch2 /= K_ESC .and. ch2 /= 'q') then
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
      case ('?')
         call cursor_help()
      case default
         ! ignore anything else (shift-click, unmapped keys)
      end select
   end subroutine kipp_action

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
      print '(a)', '  r                reset to full view      s  save png snapshot'
      print '(a)', '  ?                this help               q / Esc  back to prompt'
   end subroutine cursor_help

   ! inverse of xtrans/ytrans2: map a world (window) coordinate back to the
   ! data units st%[xy]min/max are stored in (exponent clamped for safety)
   pure function inv_x(w) result(v)
      real(real64), intent(in) :: w
      real(real64) :: v
      if (st%xlog) then
         v = 10.d0**max(min(w, 300.d0), -300.d0)
      else
         v = w
      end if
   end function inv_x

   pure function inv_y(w) result(v)
      real(real64), intent(in) :: w
      real(real64) :: v
      if (st%ylog) then
         v = 10.d0**max(min(w, 300.d0), -300.d0)
      else
         v = w
      end if
   end function inv_y

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

   ! Keep the view inside the valid data region.  Bounds are derived from
   ! the current axis arrays (xedge/ystar), so they follow xaxis/yaxis/units
   ! changes automatically.  Works in world space so log axes clamp
   ! correctly: a pan keeps its span and stops at the data edge, a view
   ! larger than the data snaps to the full range.
   subroutine clamp_view()
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

   ! lower y bound of the valid region: the centre (0) on a linear axis;
   ! on a log axis a fixed decade range below the surface maximum
   pure function ybound_lo() result(v)
      real(real64) :: v
      if (st%ylog) then
         v = maxval(ystar)/yscale()*1.d-8
      else
         v = 0.d0
      end if
   end function ybound_lo

   ! clamp the interval [a,b] into [lo,hi] preserving its span
   pure subroutine clamp1(lo, hi, a, b)
      real(real64), intent(in)    :: lo, hi
      real(real64), intent(inout) :: a, b
      real(real64) :: d
      if (b - a >= hi - lo) then
         a = lo; b = hi
      else if (a < lo) then
         d = lo - a; a = a + d; b = b + d
      else if (b > hi) then
         d = b - hi; a = a - d; b = b - d
      end if
   end subroutine clamp1

   ! First/last model strip overlapping [st%xmin, st%xmax].  xedge is
   ! monotone increasing for both xaxis modes, so a bisection finds the
   ! strip containing each window edge.
   subroutine set_visible_range()
      ivis0 = max(1_int32, min(nmodels, bisect_le(xedge, st%xmin)))
      ivis1 = max(ivis0, min(nmodels, bisect_le(xedge, st%xmax)))
   end subroutine set_visible_range

   ! largest k with arr(k) <= v, or 0 when v < arr(1)
   pure function bisect_le(arr, v) result(k)
      real(real64), intent(in) :: arr(:), v
      integer(int32) :: k, lo, hi, mid
      if (v < arr(1)) then
         k = 0
         return
      end if
      lo = 1; hi = int(size(arr), int32)
      do while (lo < hi)
         mid = (lo + hi + 1)/2
         if (arr(mid) <= v) then
            lo = mid
         else
            hi = mid - 1
         end if
      end do
      k = lo
   end function bisect_le

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

   !---------------------------------------------------------------------
   subroutine draw_scene()
      character(len=16) :: xopt, yopt
      character(len=64) :: xlabel, ylabel
      real(real64) :: wx1, wx2, wy1, wy2, vx2
      integer(int32) :: layer, fidx
      logical :: colored

      ! define convection colours (match ConvPlot.conv_hatch)
      call giza_set_colour_representation(2, 0.0d0, 0.6d0, 0.0d0)  ! conv  green
      call giza_set_colour_representation(3, 0.9d0, 0.0d0, 0.0d0)  ! semi  red
      call giza_set_colour_representation(4, 0.0d0, 0.8d0, 0.9d0)  ! neut  cyan
      call giza_set_colour_representation(5, 0.9d0, 0.0d0, 0.9d0)  ! osht  magenta
      call giza_set_colour_representation(6, 0.85d0, 0.85d0, 0.0d0)! thal  yellow

      call clamp_view()
      call set_visible_range()
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
      vx2 = merge(0.89d0, 0.95d0, colored)

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
      call draw_surface() ! surface of star

      ! axes on top
      call giza_set_colour_index(1)
      call giza_set_line_width(1.d0)
      xopt = 'BCNST'; yopt = 'BCNST'
      if (st%xlog) xopt = 'BCNSTL'
      if (st%ylog) yopt = 'BCNSTL'
      call giza_box(trim(xopt), 0.0, 0, trim(yopt), 0.0, 0)
      call labels(xlabel, ylabel)
      call giza_label(trim(xlabel), trim(ylabel), '')

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
   end subroutine draw_scene

   !---------------------------------------------------------------------
   ! draw_colorbar -- colorbar in the right margin
   !
   ! one column of colored cells with the log10 level value
   ! inside each (vertical text, white on the deep cells), gain stacked
   ! at the top (deepest blue = strongest gain), loss at the bottom
   ! (deepest magenta), a '...' separator at the zero crossing, and a
   ! second column with GAIN / log(erg/g/s) / LOSS annotations.
   subroutine draw_colorbar(layer)
      integer(int32), intent(in) :: layer
      integer(int32) :: gmax, lmax, gmin, lmin, nlev, lev
      real(real64) :: dy, y0, f
      logical :: showzero
      character(len=16) :: txt

      if (.not. ecache(layer)%valid) call build_energy_cache(layer)
      gmax = ecache(layer)%gmax; lmax = ecache(layer)%lmax
      call level_mins(layer, gmin, lmin)
      lmin = max(lmin, gmin)             ! convplot clamps loss min to gain min
      showzero = (gmax > 0 .and. lmax > 0)
      nlev = gmax + lmax
      if (showzero) nlev = nlev + 1
      if (nlev <= 0) return

      dy = 1.d0/real(nlev, real64)
      call giza_set_viewport(0.90d0, 0.99d0, 0.12d0, 0.96d0)
      call giza_set_window(0.d0, 1.d0, 0.d0, 1.d0)
      call giza_set_fill(1)
      call giza_set_character_height(0.65d0)

      ! gain cells from the top; colours match draw_energy exactly
      do lev = 1, gmax
         f = real(lev, real64)/real(gmax, real64)
         call giza_set_colour_representation(7, 1.d0 - 0.85d0*f, 1.d0 - 0.85d0*f, 1.d0)
         call giza_set_colour_index(7)
         y0 = 1.d0 - real(gmax - lev + 1, real64)*dy
         call giza_rectangle(0.d0, 0.40d0, y0, y0 + dy)
         call giza_set_colour_index(merge(0, 1, lev > 6))
         write (txt, '(i0)') gmin + lev - 1
         call giza_ptext(0.20d0, y0 + 0.5d0*dy, 90.d0, 0.5d0, trim(txt))
      end do
      ! loss cells from the bottom
      do lev = 1, lmax
         f = real(lev, real64)/real(lmax, real64)
         call giza_set_colour_representation(7, 1.d0, 1.d0 - 0.85d0*f, 1.d0)
         call giza_set_colour_index(7)
         y0 = real(lmax - lev, real64)*dy
         call giza_rectangle(0.d0, 0.40d0, y0, y0 + dy)
         call giza_set_colour_index(merge(0, 1, lev > 6))
         write (txt, '(i0)') lmin + lev - 1
         call giza_ptext(0.20d0, y0 + 0.5d0*dy, 90.d0, 0.5d0, trim(txt))
      end do

      call giza_set_colour_index(1)
      if (showzero) &
         call giza_ptext(0.20d0, (real(lmax, real64) + 0.5d0)*dy, 90.d0, 0.5d0, '...')
      if (gmax > 0) call giza_ptext(0.60d0, 1.d0, 90.d0, 1.d0, 'GAIN')
      if (lmax > 0) call giza_ptext(0.60d0, 0.d0, 90.d0, 0.d0, 'LOSS')
      call giza_ptext(0.60d0, 0.5d0, 90.d0, 0.5d0, 'log(erg/g/s)')
      call giza_set_character_height(1.d0)
   end subroutine draw_colorbar

   ! minimum log10 level values (gain, loss) for a layer, from the file
   ! header.  Matches convdata.py minx[layer] = consecutive (gain, loss)
   ! pairs per layer -- the historic KEPLER field names are misleading
   ! (minloss is the nuc GAIN minimum).
   subroutine level_mins(layer, gmin, lmin)
      integer(int32), intent(in)  :: layer
      integer(int32), intent(out) :: gmin, lmin
      select case (layer)
      case (0); gmin = int(data(1)%minloss, int32); lmin = int(data(1)%mingain, int32)
      case (1); gmin = int(data(1)%minnucl, int32); lmin = int(data(1)%minnucg, int32)
      case (2); gmin = int(data(1)%minneul, int32); lmin = int(data(1)%minneug, int32)
      case default; gmin = 0; lmin = 0
      end select
   end subroutine level_mins

   ! limits are given in plotted (already y-scaled) units, so only apply log
   pure function ytrans2(v) result(p)
      real(real64), intent(in) :: v
      real(real64) :: p
      if (st%ylog) then
         p = log10(max(v, LOGMIN))
      else
         p = v
      end if
   end function ytrans2

   !---------------------------------------------------------------------
   ! Convection zones, drawn the Alex Heger way for a lightning fast renderer.
   !
   ! Instead of one filled rectangle per (model, zone) -- which is slow
   ! and re-starts the hatch on every strip -- each contiguous convective
   ! region is traced into bands whose lower/upper edges follow the zone
   ! interfaces across models.
   !
   ! All visible bands of a type are filled as ONE keyholed giza_polygon with a
   ! per-type hatch (giza_set_fill(3|4)): a single fill means giza computes
   ! the hatch pattern once, so it stays aligned across band seams.  The
   ! boundary is stroked separately from cached outline chains that follow
   ! the exact edge of the region (convplot's PathPatch edge in the type
   ! colour) -- internal seams, where the greedy tracer closes and restarts
   ! bands at merges/splits, are never part of the outline.
   !
   ! Regions are tracked greedily: for each type, an interval in model i is
   ! matched to an open band of the previous model by y-overlap (a band that
   ! finds no match is closed and emitted; an unmatched interval opens a new
   ! band).  Merges/splits close and restart bands, which is exact enough for
   ! the fill and keeps the bookkeeping bounded.
   subroutine draw_convection()
      integer(int32) :: t
      if (.not. conv_valid) call build_conv_cache()
      call giza_set_line_width(1.d0)
      do t = 1, 5
         if (conv_bands(t)%nb == 0) cycle
         call giza_set_colour_index(CI_TYPE(t))
         call set_hatch_for_type(t)
         call fill_bandset_linked(conv_bands(t))
         call draw_chainset(conv_chains(t))
      end do
   end subroutine draw_convection

   ! Trace all five convection types into the band cache (one pass each),
   ! and build each type's exact region outline: the horizontal interface
   ! edges of every interval plus, at every strip edge, the symmetric
   ! difference between the adjacent models' interval sets (y covered on
   ! one side only).  Seams where the tracer closes/restarts bands are
   ! covered on both sides, so they never enter the outline.
   subroutine build_conv_cache()
      type(tracer_t) :: tr
      integer(int32) :: t, i, j, m, pm, maxnc, ns
      real(real64), allocatable :: ivlo(:), ivhi(:), plo(:), phi(:), bp(:)
      integer(int32), allocatable :: se0(:), se1(:)
      real(real64), allocatable :: sy0(:), sy1(:)

      maxnc = 1
      do i = 1, nmodels
         maxnc = max(maxnc, int(data(i)%nconv, int32))
      end do
      call tracer_alloc(tr, 64_int32, nmodels)
      allocate (ivlo(maxnc), ivhi(maxnc), plo(maxnc), phi(maxnc))
      allocate (bp(4*maxnc + 4))

      do t = 1, 5
         call bandset_clear(conv_bands(t))
         call chainset_clear(conv_chains(t))
         call tracer_reset(tr)
         ns = 0; pm = 0
         do i = 1, nmodels
            ! intervals of this type in model i (centre -> surface order)
            m = 0
            do j = 1, int(data(i)%nconv, int32)
               if (type_of(data(i)%yzip(j)) /= t) cycle
               m = m + 1
               ivlo(m) = mbound(i, j - 1)
               ivhi(m) = mbound(i, j)
            end do
            call tracer_step(tr, conv_bands(t), i, ivlo, ivhi, m)
            ! outline: vertical boundary at strip edge i, horizontals of model i
            call symdiff_append(plo, phi, pm, ivlo, ivhi, m, i, bp, &
                                se0, se1, sy0, sy1, ns)
            do j = 1, m
               if (ivhi(j) <= ivlo(j)) cycle
               call seg_append(se0, se1, sy0, sy1, ns, i, i + 1, ivlo(j), ivlo(j))
               call seg_append(se0, se1, sy0, sy1, ns, i, i + 1, ivhi(j), ivhi(j))
            end do
            pm = m; plo(1:m) = ivlo(1:m); phi(1:m) = ivhi(1:m)
         end do
         call tracer_flush(tr, conv_bands(t))
         ! right boundary of the last model
         call symdiff_append(plo, phi, pm, ivlo, ivhi, 0_int32, nmodels + 1, bp, &
                             se0, se1, sy0, sy1, ns)
         call build_chains(conv_chains(t), se0, se1, sy0, sy1, ns)
      end do
      deallocate (ivlo, ivhi, plo, phi, bp)
      call tracer_dealloc(tr)
      conv_valid = .true.
   end subroutine build_conv_cache

   ! per-type hatch matching ConvPlot.conv_hatch: conv '/', thal '\', the
   ! remaining (semiconv/neutral/overshoot) crossed at varying density.
   subroutine set_hatch_for_type(t)
      integer(int32), intent(in) :: t
      select case (t)
      case (4)                                   ! convective  '/'
         call giza_set_fill(3); call giza_set_hatching_style(45.d0, 1.0d0, 0.d0)
      case (5)                                   ! thermohaline '\'
         call giza_set_fill(3); call giza_set_hatching_style(135.d0, 1.0d0, 0.d0)
      case (2)                                   ! overshoot   '++'
         call giza_set_fill(4); call giza_set_hatching_style(0.d0, 1.0d0, 0.d0)
      case (1)                                   ! neutral     'X'
         call giza_set_fill(4); call giza_set_hatching_style(45.d0, 1.2d0, 0.d0)
      case (3)                                   ! semiconv    'XX'
         call giza_set_fill(4); call giza_set_hatching_style(45.d0, 0.7d0, 0.d0)
      case default
         call giza_set_fill(3); call giza_set_hatching_style(45.d0, 1.0d0, 0.d0)
      end select
   end subroutine set_hatch_for_type

   !---------------------------------------------------------------------
   ! Band tracer -- see the tracer_t definition for the idea.

   subroutine tracer_alloc(tr, maxbands, nm)
      type(tracer_t), intent(out) :: tr
      integer(int32), intent(in)  :: maxbands, nm
      tr%maxbands = maxbands
      allocate (tr%i0(maxbands), tr%i1(maxbands))
      allocate (tr%opn(maxbands), tr%ext(maxbands))
      allocate (tr%ylo(maxbands, nm), tr%yhi(maxbands, nm))
      tr%opn = .false.
   end subroutine tracer_alloc

   subroutine tracer_dealloc(tr)
      type(tracer_t), intent(inout) :: tr
      deallocate (tr%i0, tr%i1, tr%opn, tr%ext, tr%ylo, tr%yhi)
      tr%maxbands = 0
   end subroutine tracer_dealloc

   ! Begin a new feature: close out any leftover bands without emitting.
   subroutine tracer_reset(tr)
      type(tracer_t), intent(inout) :: tr
      tr%opn = .false.
   end subroutine tracer_reset

   ! Feed model i's intervals (ivlo/ivhi, m of them, ascending in y).  Each
   ! interval is matched to an open band from model i-1 by overlap; unmatched
   ! intervals open new bands; bands with no continuation are stored to bs.
   subroutine tracer_step(tr, bs, i, ivlo, ivhi, m)
      type(tracer_t), intent(inout) :: tr
      type(bandset_t), intent(inout) :: bs
      integer(int32), intent(in)    :: i, m
      real(real64), intent(in)    :: ivlo(:), ivhi(:)
      integer(int32) :: k, b, newb
      logical :: matched
      tr%ext = .false.
      do k = 1, m
         matched = .false.
         do b = 1, tr%maxbands
            if (.not. tr%opn(b) .or. tr%ext(b) .or. tr%i1(b) /= i - 1) cycle
            if (ivlo(k) < tr%yhi(b, i - 1) .and. tr%ylo(b, i - 1) < ivhi(k)) then
               tr%ylo(b, i) = ivlo(k); tr%yhi(b, i) = ivhi(k)
               tr%i1(b) = i; tr%ext(b) = .true.
               matched = .true.
               exit
            end if
         end do
         if (matched) cycle
         newb = 0
         do b = 1, tr%maxbands
            if (.not. tr%opn(b)) then; newb = b; exit; end if
         end do
         if (newb > 0) then
            tr%opn(newb) = .true.; tr%ext(newb) = .true.
            tr%i0(newb) = i; tr%i1(newb) = i
            tr%ylo(newb, i) = ivlo(k); tr%yhi(newb, i) = ivhi(k)
         else
            ! overflow fallback: store as a single-model band
            call bandset_append(bs, i, i, ivlo(k:k), ivhi(k:k))
         end if
      end do
      do b = 1, tr%maxbands
         if (tr%opn(b) .and. .not. tr%ext(b)) then
            call tracer_close(tr, bs, b)
         end if
      end do
   end subroutine tracer_step

   ! Store all bands still open at the final model.
   subroutine tracer_flush(tr, bs)
      type(tracer_t), intent(inout) :: tr
      type(bandset_t), intent(inout) :: bs
      integer(int32) :: b
      do b = 1, tr%maxbands
         if (tr%opn(b)) call tracer_close(tr, bs, b)
      end do
   end subroutine tracer_flush

   subroutine tracer_close(tr, bs, b)
      type(tracer_t), intent(inout) :: tr
      type(bandset_t), intent(inout) :: bs
      integer(int32), intent(in)    :: b
      call bandset_append(bs, tr%i0(b), tr%i1(b), &
                          tr%ylo(b, tr%i0(b):tr%i1(b)), tr%yhi(b, tr%i0(b):tr%i1(b)))
      tr%opn(b) = .false.
   end subroutine tracer_close

   !---------------------------------------------------------------------
   ! Band cache plumbing.

   subroutine bandset_clear(bs)
      type(bandset_t), intent(inout) :: bs
      if (allocated(bs%b)) deallocate (bs%b)
      bs%nb = 0
   end subroutine bandset_clear

   ! append one band (grow-by-doubling)
   subroutine bandset_append(bs, i0, i1, ylo, yhi)
      type(bandset_t), intent(inout) :: bs
      integer(int32), intent(in)    :: i0, i1
      real(real64), intent(in)    :: ylo(:), yhi(:)
      type(band_t), allocatable :: tmp(:)
      integer(int32) :: cap
      if (.not. allocated(bs%b)) allocate (bs%b(8))
      cap = int(size(bs%b), int32)
      if (bs%nb == cap) then
         allocate (tmp(2*cap))
         tmp(1:cap) = bs%b
         call move_alloc(tmp, bs%b)
      end if
      bs%nb = bs%nb + 1
      bs%b(bs%nb)%i0 = i0
      bs%b(bs%nb)%i1 = i1
      bs%b(bs%nb)%ylo = ylo
      bs%b(bs%nb)%yhi = yhi
   end subroutine bandset_append

   ! drop every cached band (file load or axis rebuild)
   subroutine cache_invalidate()
      integer(int32) :: t, l
      do t = 1, 5
         call bandset_clear(conv_bands(t))
         call chainset_clear(conv_chains(t))
      end do
      conv_valid = .false.
      do l = 0, 2
         if (allocated(ecache(l)%gain)) deallocate (ecache(l)%gain)
         if (allocated(ecache(l)%loss)) deallocate (ecache(l)%loss)
         ecache(l)%gmax = 0; ecache(l)%lmax = 0
         ecache(l)%valid = .false.
      end do
      ! field band caches are view-dependent (mass/radius interfaces), so
      ! drop and re-size them to the current registry on every invalidation
      if (allocated(fcache)) deallocate (fcache)
      if (nfields > 0) allocate (fcache(nfields))
   end subroutine cache_invalidate

   subroutine draw_bandset(bs)
      type(bandset_t), intent(in) :: bs
      integer(int32) :: k
      do k = 1, bs%nb
         call draw_band(bs%b(k))
      end do
   end subroutine draw_bandset

   ! true when the visible stretch (models j0..j1) of band bd overlaps the
   ! y-window.  bands with no y-overlap must not be emitted: linked into
   ! the keyholed fill polygon their bridges cross the window, and giza
   ! hatches by clip + stroke over the clip extents bbox, which the cairo
   ! xlib backend does not confine to a zero-area keyhole clip -- hatch
   ! lines flood the axes box on /xw (task 39)
   pure function band_y_visible(bd, j0, j1) result(vis)
      type(band_t), intent(in) :: bd
      integer(int32), intent(in) :: j0, j1
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

   ! Emit one cached band as a single polygon: trace the lower interface
   ! left->right as a staircase, then the upper interface right->left.
   ! Only the visible model range is emitted; a band cut by the window
   ! edge is closed there (the polygon side lands on the window boundary).
   subroutine draw_band(bd)
      type(band_t), intent(in) :: bd
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

   ! Fill all visible bands of one type as a single keyholed polygon: band
   ! loops are linked by bridges between their anchor points, and every
   ! bridge is traversed once out and once back along the same line, so it
   ! encloses no area (invisible under cairo's winding fill).  One polygon
   ! means one giza fill, so the hatch pattern is computed once and stays
   ! aligned across all bands of the type.
   subroutine fill_bandset_linked(bs)
      type(bandset_t), intent(in) :: bs
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

   ! Stroke the cached region outline: each chain is a polyline along the
   ! exact boundary of the type's region.  Only points on visible strip
   ! edges are emitted, with one point of lead-in/out so a cut chain
   ! continues through the window edge (giza clips it there).
   subroutine draw_chainset(cs)
      type(chainset_t), intent(in) :: cs
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

   !---------------------------------------------------------------------
   ! Region outline plumbing.  Boundary segments live on the strip-edge
   ! grid: a segment is (e0,y0)-(e1,y1) with either e0 == e1 (vertical,
   ! at strip edge e0) or y0 == y1 and e1 == e0+1 (horizontal interface).

   ! append one segment (grow-by-doubling)
   subroutine seg_append(se0, se1, sy0, sy1, ns, e0, e1, y0, y1)
      integer(int32), allocatable, intent(inout) :: se0(:), se1(:)
      real(real64), allocatable, intent(inout) :: sy0(:), sy1(:)
      integer(int32), intent(inout) :: ns
      integer(int32), intent(in)    :: e0, e1
      real(real64), intent(in)    :: y0, y1
      ns = ns + 1
      call grow_i32(se0, ns); call grow_i32(se1, ns)
      call grow_r64(sy0, ns); call grow_r64(sy1, ns)
      se0(ns) = e0; se1(ns) = e1
      sy0(ns) = y0; sy1(ns) = y1
   end subroutine seg_append

   ! Append the vertical outline segments at strip edge e: the spans of y
   ! covered by exactly one of the two adjacent models' interval sets.
   ! All values are exact copies of the mbound reals, so every elementary
   ! span between sorted breakpoints is either fully inside or fully
   ! outside each interval and the membership tests are exact.
   subroutine symdiff_append(alo, ahi, na, blo, bhi, nb, e, bp, &
                             se0, se1, sy0, sy1, ns)
      real(real64), intent(in)    :: alo(:), ahi(:), blo(:), bhi(:)
      integer(int32), intent(in)    :: na, nb, e
      real(real64), intent(inout) :: bp(:)
      integer(int32), allocatable, intent(inout) :: se0(:), se1(:)
      real(real64), allocatable, intent(inout) :: sy0(:), sy1(:)
      integer(int32), intent(inout) :: ns
      integer(int32) :: k, p, nbp
      real(real64) :: y0, y1, v
      logical :: ina, inb

      nbp = 0
      do k = 1, na
         if (ahi(k) > alo(k)) then
            nbp = nbp + 1; bp(nbp) = alo(k)
            nbp = nbp + 1; bp(nbp) = ahi(k)
         end if
      end do
      do k = 1, nb
         if (bhi(k) > blo(k)) then
            nbp = nbp + 1; bp(nbp) = blo(k)
            nbp = nbp + 1; bp(nbp) = bhi(k)
         end if
      end do
      if (nbp < 2) return
      ! insertion sort: the lists are tiny and already mostly ordered
      do p = 2, nbp
         v = bp(p)
         k = p - 1
         do while (k >= 1)
            if (bp(k) <= v) exit
            bp(k + 1) = bp(k)
            k = k - 1
         end do
         bp(k + 1) = v
      end do
      do p = 1, nbp - 1
         y0 = bp(p); y1 = bp(p + 1)
         if (y1 <= y0) cycle
         ina = .false.
         do k = 1, na
            if (alo(k) <= y0 .and. y1 <= ahi(k)) then
               ina = .true.; exit
            end if
         end do
         inb = .false.
         do k = 1, nb
            if (blo(k) <= y0 .and. y1 <= bhi(k)) then
               inb = .true.; exit
            end if
         end do
         if (ina .neqv. inb) then
            ! merge with the previous segment when contiguous
            if (ns > 0) then
               if (se0(ns) == e .and. se1(ns) == e .and. sy1(ns) == y0) then
                  sy1(ns) = y1
                  cycle
               end if
            end if
            call seg_append(se0, se1, sy0, sy1, ns, e, e, y0, y1)
         end if
      end do
   end subroutine symdiff_append

   ! Link the outline segments into polyline chains by walking shared
   ! endpoints (exact equality; see symdiff_append).  Where more than two
   ! segments meet, the walker picks any continuation -- every segment is
   ! drawn exactly once either way.
   subroutine build_chains(cs, se0, se1, sy0, sy1, ns)
      type(chainset_t), intent(inout) :: cs
      integer(int32), intent(in) :: ns
      integer(int32), intent(in) :: se0(:), se1(:)
      real(real64), intent(in) :: sy0(:), sy1(:)
      logical, allocatable :: used(:)
      integer(int32), allocatable :: cnt(:), off(:), ids(:), fil(:)
      integer(int32), allocatable :: cei(:)
      real(real64), allocatable :: cy(:)
      integer(int32) :: nedge, s, e, k, cn, tmpe
      real(real64) :: tmpy

      if (ns == 0) return
      ! bucket the segments by the strip edges they touch (CSR layout)
      nedge = nmodels + 1
      allocate (used(ns)); used = .false.
      allocate (cnt(nedge), off(nedge + 1), fil(nedge))
      cnt = 0
      do s = 1, ns
         cnt(se0(s)) = cnt(se0(s)) + 1
         if (se1(s) /= se0(s)) cnt(se1(s)) = cnt(se1(s)) + 1
      end do
      off(1) = 1
      do e = 1, nedge
         off(e + 1) = off(e) + cnt(e)
      end do
      allocate (ids(off(nedge + 1) - 1))
      fil = off(1:nedge)
      do s = 1, ns
         ids(fil(se0(s))) = s; fil(se0(s)) = fil(se0(s)) + 1
         if (se1(s) /= se0(s)) then
            ids(fil(se1(s))) = s; fil(se1(s)) = fil(se1(s)) + 1
         end if
      end do

      do s = 1, ns
         if (used(s)) cycle
         used(s) = .true.
         cn = 0
         call chain_push(cei, cy, cn, se0(s), sy0(s))
         call chain_push(cei, cy, cn, se1(s), sy1(s))
         call chain_extend()
         ! reverse and extend from the other end too
         do k = 1, cn/2
            tmpe = cei(k); cei(k) = cei(cn + 1 - k); cei(cn + 1 - k) = tmpe
            tmpy = cy(k); cy(k) = cy(cn + 1 - k); cy(cn + 1 - k) = tmpy
         end do
         call chain_extend()
         call chainset_append(cs, cei, cy, cn)
      end do

   contains

      ! extend the chain from its tail while an unused segment connects
      subroutine chain_extend()
         integer(int32) :: et, kk, s2
         real(real64) :: yt
         logical :: found
         do
            et = cei(cn); yt = cy(cn)
            found = .false.
            do kk = off(et), off(et + 1) - 1
               s2 = ids(kk)
               if (used(s2)) cycle
               if (se0(s2) == et .and. sy0(s2) == yt) then
                  used(s2) = .true.
                  call chain_push(cei, cy, cn, se1(s2), sy1(s2))
                  found = .true.
                  exit
               else if (se1(s2) == et .and. sy1(s2) == yt) then
                  used(s2) = .true.
                  call chain_push(cei, cy, cn, se0(s2), sy0(s2))
                  found = .true.
                  exit
               end if
            end do
            if (.not. found) return
         end do
      end subroutine chain_extend
   end subroutine build_chains

   subroutine chain_push(cei, cy, cn, e, y)
      integer(int32), allocatable, intent(inout) :: cei(:)
      real(real64), allocatable, intent(inout) :: cy(:)
      integer(int32), intent(inout) :: cn
      integer(int32), intent(in) :: e
      real(real64), intent(in) :: y
      cn = cn + 1
      call grow_i32(cei, cn)
      call grow_r64(cy, cn)
      cei(cn) = e; cy(cn) = y
   end subroutine chain_push

   subroutine chainset_clear(cs)
      type(chainset_t), intent(inout) :: cs
      if (allocated(cs%c)) deallocate (cs%c)
      cs%nc = 0
   end subroutine chainset_clear

   ! store one chain (grow-by-doubling, like bandset_append)
   subroutine chainset_append(cs, cei, cy, cn)
      type(chainset_t), intent(inout) :: cs
      integer(int32), intent(in) :: cei(:), cn
      real(real64), intent(in) :: cy(:)
      type(chain_t), allocatable :: tmp(:)
      integer(int32) :: cap
      if (cn < 2) return
      if (.not. allocated(cs%c)) allocate (cs%c(8))
      cap = int(size(cs%c), int32)
      if (cs%nc == cap) then
         allocate (tmp(2*cap))
         tmp(1:cap) = cs%c
         call move_alloc(tmp, cs%c)
      end if
      cs%nc = cs%nc + 1
      cs%c(cs%nc)%n = cn
      cs%c(cs%nc)%ei = cei(1:cn)
      cs%c(cs%nc)%y = cy(1:cn)
   end subroutine chainset_append

   ! growable-array helpers (double the capacity when needed)
   subroutine grow_i32(a, need)
      integer(int32), allocatable, intent(inout) :: a(:)
      integer(int32), intent(in) :: need
      integer(int32), allocatable :: tmp(:)
      integer(int32) :: cap
      if (.not. allocated(a)) then
         allocate (a(max(need, 64_int32)))
         return
      end if
      cap = int(size(a), int32)
      if (need <= cap) return
      allocate (tmp(max(need, 2*cap)))
      tmp(1:cap) = a
      call move_alloc(tmp, a)
   end subroutine grow_i32

   subroutine grow_r64(a, need)
      real(real64), allocatable, intent(inout) :: a(:)
      integer(int32), intent(in) :: need
      real(real64), allocatable :: tmp(:)
      integer(int32) :: cap
      if (.not. allocated(a)) then
         allocate (a(max(need, 64_int32)))
         return
      end if
      cap = int(size(a), int32)
      if (need <= cap) return
      allocate (tmp(max(need, 2*cap)))
      tmp(1:cap) = a
      call move_alloc(tmp, a)
   end subroutine grow_r64

   ! clamp transformed coordinates to the emit box (see draw_scene)
   pure function clampx(v) result(r)
      real(real64), intent(in) :: v
      real(real64) :: r
      r = min(max(v, exlo), exhi)
   end function clampx

   pure function clampy(v) result(r)
      real(real64), intent(in) :: v
      real(real64) :: r
      r = min(max(v, eylo), eyhi)
   end function clampy

   ! grow the polygon emit scratch when a caller needs more room
   subroutine ensure_scratch(need)
      integer(int32), intent(in) :: need
      if (allocated(epx)) then
         if (int(size(epx), int32) >= need) return
         deallocate (epx, epy)
      end if
      allocate (epx(need), epy(need))
   end subroutine ensure_scratch

   !---------------------------------------------------------------------
   ! Energy-generation field (epsnuc).  Maps the `color` field name to a
   ! cnv layer; -1 means "convection types" (no energy overlay).
   !   epsnuc|enuc|nuc -> nuclear energy generation (signed: +gain/-loss)
   !   nuk|loss        -> nuclear energy loss layer
   !   neu|neutrino    -> neutrino layer
   pure function layer_of_cfield() result(layer)
      integer(int32) :: layer
      select case (trim(st%cfield))
      case ('epsnuc', 'enuc', 'nuc'); layer = 0
      case ('nuk', 'loss'); layer = 1
      case ('neu', 'neutrino'); layer = 2
      case default; layer = -1
      end select
   end function layer_of_cfield

   ! resolve st%cfield to a registered colour-field index (1..nfields), or 0.
   ! matches the source column name exactly first, then a few friendly
   ! aliases against the canonical names the readers emit.
   pure function field_of_cfield() result(f)
      integer(int32) :: f, k
      character(len=len(st%cfield)) :: want
      f = 0
      if (.not. allocated(field_names)) return
      want = trim(st%cfield)
      do k = 1, nfields
         if (trim(field_names(k)) == want) then
            f = k
            return
         end if
      end do
      ! aliases: try each canonical name a group maps to, first present wins
      select case (want)
      case ('temperature', 'temp', 'T')
         f = first_field(['T_K   ', 'logT  ', 'T     '])
      case ('density', 'rho', 'Rho')
         f = first_field(['rho_gcc', 'logRho ', 'rho    '])
      case ('luminosity', 'lum', 'L')
         f = first_field(['L_erg_s   ', 'logL      ', 'luminosity'])
      case ('pressure', 'P')
         f = first_field(['logP    ', 'pressure'])
      end select
   end function field_of_cfield

   ! index of the first of the given canonical names that is registered, or 0
   pure function first_field(names) result(f)
      character(len=*), intent(in) :: names(:)
      integer(int32) :: f, i, k
      f = 0
      if (.not. allocated(field_names)) return
      do i = 1, size(names)
         do k = 1, nfields
            if (trim(field_names(k)) == trim(names(i))) then
               f = k
               return
            end if
         end do
      end do
   end function first_field

   ! number of step-function entries in a model's field-f layer
   pure function field_layer_len(i, f) result(n)
      integer(int32), intent(in) :: i, f
      integer(int32) :: n
      n = 0
      if (f < 1 .or. f > data(i)%nfld) return
      n = data(i)%fld(f)%n
   end function field_layer_len

   ! copy a model's field-f (level, coord-index) step function into buffers,
   ! parallel to get_layer_buf for the energy layers
   subroutine get_field_buf(i, f, vals, idxs, n)
      integer(int32), intent(in)  :: i, f
      integer(int32), intent(out) :: vals(:), idxs(:)
      integer(int32), intent(out) :: n
      n = field_layer_len(i, f)
      if (n > 0) then
         vals(1:n) = int(data(i)%fld(f)%lev, int32)
         idxs(1:n) = int(data(i)%fld(f)%idx, int32)
      end if
   end subroutine get_field_buf

   ! Trace every contour bin of field f into a nested bandset (bin 1 covers the
   ! whole star, each higher bin nests inward), reusing the energy band tracer.
   subroutine build_field_cache(f)
      integer(int32), intent(in) :: f
      type(tracer_t) :: tr
      integer(int32) :: i, n, lev, maxn, m
      integer(int32), allocatable :: lvals(:), lidxs(:)
      real(real64), allocatable   :: ivlo(:), ivhi(:)
      associate (fc => fcache(f))
         if (allocated(fc%band)) deallocate (fc%band)
         fc%nlev = FIELD_NBINS
         allocate (fc%band(fc%nlev))
         maxn = 1
         do i = 1, nmodels
            maxn = max(maxn, field_layer_len(i, f))
         end do
         call tracer_alloc(tr, 64_int32, nmodels)
         allocate (lvals(maxn), lidxs(maxn), ivlo(maxn + 1), ivhi(maxn + 1))
         do lev = 1, fc%nlev
            call tracer_reset(tr)
            do i = 1, nmodels
               call get_field_buf(i, f, lvals, lidxs, n)
               call level_intervals(i, lvals, lidxs, n, lev, ivlo, ivhi, m)
               call tracer_step(tr, fc%band(lev), i, ivlo, ivhi, m)
            end do
            call tracer_flush(tr, fc%band(lev))
         end do
         deallocate (lvals, lidxs, ivlo, ivhi)
         call tracer_dealloc(tr)
         fc%valid = .true.
      end associate
   end subroutine build_field_cache

   ! Generic colour field: fill each contour bin as nested solid bands shaded
   ! by the colormap, coolest bin (1) first so hotter bins overpaint inward.
   subroutine draw_field(f)
      integer(int32), intent(in) :: f
      integer(int32) :: lev
      real(real64) :: t, r, g, b
      if (f < 1 .or. f > nfields) return
      if (.not. fcache(f)%valid) call build_field_cache(f)

      call giza_set_fill(1)
      call giza_set_line_width(1.d0)
      associate (fc => fcache(f))
         do lev = 1, fc%nlev
            t = (real(lev, real64) - 0.5d0)/real(fc%nlev, real64)
            call colormap(t, r, g, b)
            call giza_set_colour_representation(7, r, g, b)
            call giza_set_colour_index(7)
            call draw_bandset(fc%band(lev))
         end do
      end associate
   end subroutine draw_field

   ! colorbar for a generic column field: a smooth colormap strip spanning
   ! [vmin, vmax] across the whole run, value ticks written up the strip, and
   ! the column name (with 'log' when log-binned) as a vertical title.
   subroutine draw_field_colorbar(f)
      integer(int32), intent(in) :: f
      integer(int32), parameter :: NTICK = 5
      integer(int32) :: lev, k
      real(real64) :: dy, y0, t, r, g, b, frac
      character(len=24) :: txt
      character(len=40) :: title

      call giza_set_viewport(0.90d0, 0.99d0, 0.12d0, 0.96d0)
      call giza_set_window(0.d0, 1.d0, 0.d0, 1.d0)
      call giza_set_fill(1)
      call giza_set_character_height(0.65d0)

      dy = 1.d0/real(FIELD_NBINS, real64)
      do lev = 1, FIELD_NBINS
         t = (real(lev, real64) - 0.5d0)/real(FIELD_NBINS, real64)
         call colormap(t, r, g, b)
         call giza_set_colour_representation(7, r, g, b)
         call giza_set_colour_index(7)
         y0 = real(lev - 1, real64)*dy
         call giza_rectangle(0.d0, 0.40d0, y0, y0 + dy)
      end do

      ! value ticks written up the strip, dark text on the light (high) end
      ! and light text on the dark (low) end so they stay legible
      do k = 0, NTICK
         frac = real(k, real64)/real(NTICK, real64)
         call fmt_field_value(f, frac, txt)
         call giza_set_colour_index(merge(1, 0, frac > 0.55d0))
         ! inset the end ticks so they clear the strip edges / plot frame
         call giza_ptext(0.20d0, 0.03d0 + frac*0.94d0, 90.d0, 0.5d0, trim(txt))
      end do

      title = trim(field_names(f))
      if (field_log(f)) title = 'log '//trim(title)
      call giza_set_colour_index(1)
      call giza_ptext(0.65d0, 0.5d0, 90.d0, 0.5d0, trim(title))
      call giza_set_character_height(1.d0)
   end subroutine draw_field_colorbar

   ! format the field value at fractional position frac in [0,1] up the strip
   subroutine fmt_field_value(f, frac, txt)
      integer(int32), intent(in) :: f
      real(real64), intent(in) :: frac
      character(len=*), intent(out) :: txt
      real(real64) :: a, b, v
      a = field_vmin(f); b = field_vmax(f)
      if (field_log(f)) then
         a = log10(max(a, LOGMIN)); b = log10(max(b, LOGMIN))
         v = a + frac*(b - a)          ! label the log value directly
         write (txt, '(f0.2)') v
      else
         v = a + frac*(b - a)
         if (abs(v) >= 1.d4 .or. (v /= 0.d0 .and. abs(v) < 1.d-2)) then
            write (txt, '(es9.2)') v
         else
            write (txt, '(f0.3)') v
         end if
      end if
   end subroutine fmt_field_value

   ! perceptual-ish sequential colormap (viridis approximation) mapping
   ! t in [0,1] to r,g,b in [0,1]; low = dark blue/purple, high = yellow
   pure subroutine colormap(t, r, g, b)
      real(real64), intent(in) :: t
      real(real64), intent(out) :: r, g, b
      integer(int32), parameter :: NC = 8
      real(real64), parameter :: cr(NC) = &
         [0.267d0, 0.283d0, 0.254d0, 0.207d0, 0.164d0, 0.478d0, 0.741d0, 0.993d0]
      real(real64), parameter :: cg(NC) = &
         [0.005d0, 0.141d0, 0.265d0, 0.372d0, 0.471d0, 0.821d0, 0.873d0, 0.906d0]
      real(real64), parameter :: cb(NC) = &
         [0.329d0, 0.458d0, 0.530d0, 0.553d0, 0.558d0, 0.318d0, 0.150d0, 0.144d0]
      real(real64) :: x, u
      integer(int32) :: i0, i1
      x = min(max(t, 0.d0), 1.d0)*real(NC - 1, real64)
      i0 = int(x) + 1
      if (i0 >= NC) i0 = NC - 1
      i1 = i0 + 1
      u = x - real(i0 - 1, real64)
      r = cr(i0) + u*(cr(i1) - cr(i0))
      g = cg(i0) + u*(cg(i1) - cg(i0))
      b = cb(i0) + u*(cb(i1) - cb(i0))
   end subroutine colormap

   ! copy a model's level-value / coordinate-index arrays for a layer
   subroutine get_layer(i, layer, vals, idxs, n)
      integer(int32), intent(in)  :: i, layer
      integer(int32), allocatable, intent(out) :: vals(:), idxs(:)
      integer(int32), intent(out) :: n
      select case (layer)
      case (0); n = data(i)%nnuc
      case (1); n = data(i)%nnuk
      case (2); n = data(i)%nneu
      case default; n = 0
      end select
      allocate (vals(n), idxs(n))
      if (n > 0) then
         select case (layer)
         case (0); vals = int(data(i)%nuc, int32); idxs = int(data(i)%inuc, int32)
         case (1); vals = int(data(i)%nuk, int32); idxs = int(data(i)%inuk, int32)
         case (2); vals = int(data(i)%neu, int32); idxs = int(data(i)%ineu, int32)
         end select
      end if
   end subroutine get_layer

   ! number of levels in a model's layer (for scratch sizing)
   pure function layer_len(i, layer) result(n)
      integer(int32), intent(in) :: i, layer
      integer(int32) :: n
      select case (layer)
      case (0); n = int(data(i)%nnuc, int32)
      case (1); n = int(data(i)%nnuk, int32)
      case (2); n = int(data(i)%nneu, int32)
      case default; n = 0
      end select
   end function layer_len

   ! like get_layer but writes into caller-supplied buffers (no allocation),
   ! so the per-(model,level) inner loops in draw_energy stay alloc-free
   subroutine get_layer_buf(i, layer, vals, idxs, n)
      integer(int32), intent(in)  :: i, layer
      integer(int32), intent(out) :: vals(:), idxs(:)
      integer(int32), intent(out) :: n
      n = layer_len(i, layer)
      if (n > 0) then
         select case (layer)
         case (0); vals(1:n) = int(data(i)%nuc, int32); idxs(1:n) = int(data(i)%inuc, int32)
         case (1); vals(1:n) = int(data(i)%nuk, int32); idxs(1:n) = int(data(i)%inuk, int32)
         case (2); vals(1:n) = int(data(i)%neu, int32); idxs(1:n) = int(data(i)%ineu, int32)
         case default; stop "impossible case hit"
         end select
      end if
   end subroutine get_layer_buf

   ! mass/radius coordinate at KEPLER coordinate index ic (1-based)
   pure function coord_at(i, ic) result(c)
      integer(int32), intent(in) :: i, ic
      real(real64) :: c
      integer(int32) :: j
      j = max(1_int32, min(ic, data(i)%ncoord))
      if (st%yaxis == "radius") then
         c = data(i)%rncoord(j)
      else
         c = data(i)%xmcoord(j)
      end if
   end function coord_at

   ! max gain (positive) and loss (|negative|) levels across all models
   subroutine scan_levels(layer, gmax, lmax)
      integer(int32), intent(in)  :: layer
      integer(int32), intent(out) :: gmax, lmax
      integer(int32) :: i, n, k
      integer(int32), allocatable :: vals(:), idxs(:)
      gmax = 0; lmax = 0
      do i = 1, nmodels
         call get_layer(i, layer, vals, idxs, n)
         do k = 1, n
            gmax = max(gmax, vals(k))
            lmax = max(lmax, -vals(k))
         end do
         deallocate (vals, idxs)
      end do
   end subroutine scan_levels

   ! Mass intervals of one model where the layer field reaches integer level L
   ! -- ports extract_layer (convdata.py:67).  Returns m intervals in
   ! ivlo/ivhi (cgs coords) instead of drawing, so the band tracer can fill
   ! them as polygons.
   subroutine level_intervals(i, vals, idxs, n, L, ivlo, ivhi, m)
      integer(int32), intent(in)  :: i, n, L
      integer(int32), intent(in)  :: vals(:), idxs(:)
      real(real64), intent(out) :: ivlo(:), ivhi(:)
      integer(int32), intent(out) :: m
      integer(int32) :: pf, xprev, xcur
      logical :: rising, falling, inb
      real(real64) :: ylo
      m = 0; inb = .false.; ylo = 0.d0
      do pf = 1, n
         if (pf == 1) then
            xprev = 0
         else
            xprev = vals(pf - 1)
         end if
         xcur = vals(pf)
         if (L > 0) then
            rising = (xprev < L .and. xcur >= L)
            falling = (xprev >= L .and. xcur < L)
         else
            rising = (xprev > L .and. xcur <= L)
            falling = (xprev <= L .and. xcur > L)
         end if
         if (rising) then
            ylo = coord_at(i, idxs(pf)); inb = .true.
         else if (falling .and. inb) then
            m = m + 1; ivlo(m) = ylo; ivhi(m) = coord_at(i, idxs(pf))
            inb = .false.
         end if
      end do
      if (inb) then
         m = m + 1; ivlo(m) = ylo; ivhi(m) = coord_at(i, data(i)%ncoord)
      end if
   end subroutine level_intervals

   ! Energy field: each integer contour level becomes a set of nested filled
   ! polygons (via the cached band tracer), the same way convection zones are
   ! traced -- one polygon per contiguous run of models, not per model.
   subroutine draw_energy(layer)
      integer(int32), intent(in) :: layer
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

   ! Trace every gain/loss contour level of a layer into its band cache.
   subroutine build_energy_cache(layer)
      integer(int32), intent(in) :: layer
      type(tracer_t) :: tr
      integer(int32) :: i, n, lev, maxn, m
      integer(int32), allocatable :: lvals(:), lidxs(:)
      real(real64), allocatable   :: ivlo(:), ivhi(:)
      associate (ec => ecache(layer))
         if (allocated(ec%gain)) deallocate (ec%gain)
         if (allocated(ec%loss)) deallocate (ec%loss)
         call scan_levels(layer, ec%gmax, ec%lmax)
         allocate (ec%gain(ec%gmax), ec%loss(ec%lmax))
         maxn = 1
         do i = 1, nmodels
            maxn = max(maxn, layer_len(i, layer))
         end do
         call tracer_alloc(tr, 64_int32, nmodels)
         allocate (lvals(maxn), lidxs(maxn), ivlo(maxn + 1), ivhi(maxn + 1))
         do lev = 1, ec%lmax
            call tracer_reset(tr)
            do i = 1, nmodels
               call get_layer_buf(i, layer, lvals, lidxs, n)
               call level_intervals(i, lvals, lidxs, n, -lev, ivlo, ivhi, m)
               call tracer_step(tr, ec%loss(lev), i, ivlo, ivhi, m)
            end do
            call tracer_flush(tr, ec%loss(lev))
         end do
         do lev = 1, ec%gmax
            call tracer_reset(tr)
            do i = 1, nmodels
               call get_layer_buf(i, layer, lvals, lidxs, n)
               call level_intervals(i, lvals, lidxs, n, lev, ivlo, ivhi, m)
               call tracer_step(tr, ec%gain(lev), i, ivlo, ivhi, m)
            end do
            call tracer_flush(tr, ec%gain(lev))
         end do
         deallocate (lvals, lidxs, ivlo, ivhi)
         call tracer_dealloc(tr)
         ec%valid = .true.
      end associate
   end subroutine build_energy_cache

   ! Surface line, clipped to the visible models (one extra point each
   ! side so the line still crosses the window edge).
   subroutine draw_surface()
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

   !---------------------------------------------------------------------
   subroutine labels(xlabel, ylabel)
      character(len=*), intent(out) :: xlabel, ylabel
      if (st%xaxis == 'model') then
         xlabel = 'model number'
      else
         xlabel = 'time (yr)'
      end if
      if (st%xlog) xlabel = 'log '//trim(xlabel)
      if (st%yaxis == 'radius') then
         ylabel = merge('radius (Rsun)    ', 'radius (cm)      ', st%ysolar)
      else
         ylabel = merge('enclosed mass (Msun)', 'enclosed mass (g)   ', st%ysolar)
      end if
      if (st%ylog) ylabel = 'log '//trim(ylabel)
   end subroutine labels

   !---------------------------------------------------------------------
   ! Rebuild x/y arrays after an axis-type change (called by the REPL).
   ! Cached bands hold mass|radius interfaces, so they must be retraced.
   subroutine kipp_rebuild()
      call cache_invalidate()
      call build_axes()
   end subroutine kipp_rebuild

   ! print the colour fields available for `color <name>`, with the value
   ! range and binning each carries.  the fixed energy/convtype selectors are
   ! always available; the rest come from the loaded source's columns.
   subroutine kipp_list_fields()
      integer(int32) :: k
      character(len=8) :: scale
      print '(a)', 'color selectors:'
      print '(a)', '  convtype   (no colour field, convection hatch only)'
      print '(a)', '  epsnuc     nuclear energy layer (log erg/g/s)'
      print '(a)', '  neu        neutrino energy layer (log erg/g/s)'
      if (.not. allocated(field_names) .or. nfields < 1) then
         print '(a)', '  (no extra column fields in this source)'
         return
      end if
      print '(a)', '  column fields (min .. max across the run):'
      do k = 1, nfields
         scale = merge('log ', 'lin ', field_log(k))
         print '(a,a16,a,a,es11.3,a,es11.3)', '    ', field_names(k), &
            '  ', trim(scale), field_vmin(k), ' .. ', field_vmax(k)
      end do
   end subroutine kipp_list_fields

end module kipp
