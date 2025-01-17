!***********************************************************************
!*                   GNU Lesser General Public License
!*
!* This file is part of the FV3 dynamical core.
!*
!* The FV3 dynamical core is free software: you can redistribute it
!* and/or modify it under the terms of the
!* GNU Lesser General Public License as published by the
!* Free Software Foundation, either version 3 of the License, or
!* (at your option) any later version.
!*
!* The FV3 dynamical core is distributed in the hope that it will be
!* useful, but WITHOUT ANY WARRANTY; without even the implied warranty
!* of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
!* See the GNU General Public License for more details.
!*
!* You should have received a copy of the GNU Lesser General Public
!* License along with the FV3 dynamical core.
!* If not, see <http://www.gnu.org/licenses/>.
!***********************************************************************

module init_hydro_mod

      use constants_mod,      only: grav, rdgas, rvgas, kappa, stefan
      use fv_grid_utils_mod,  only: g_sum
      use fv_mp_mod,          only: is_master
      use field_manager_mod,  only: MODEL_ATMOS
      use tracer_manager_mod, only: get_tracer_index
      use mpp_domains_mod,    only: domain2d
      use fv_arrays_mod,      only: R_GRID
      use fms_mod,            only: FATAL, stdlog, mpp_error, check_nml_error
      use mpp_mod,            only: input_nml_file
      use interp_mod,         only: linear_log_interp
      use netcdf
!     use fv_diagnostics_mod, only: prt_maxmin

      implicit none
      private

      public :: p_var, hydro_eq, hydro_eq_ext

! HI added:
!---------------------------------------------------------------------------------------
! Namelist values to read in 
!---------------------------------------------------------------------------------------
      
!      namelist /initialisation_nml/ init_type, ts, T_strat, S, f, tau_sw, tau_lw, Tint, &
!           surface_pressure
!

      namelist /initialisation_nml/ init_type, ts, t_strat, S, f, tau_sw, tau_lw, Tint, surface_pressure,&
           tp_file
      
! Default values of namelist arguments
      integer :: init_type = 1   ! Select initialisation type:
! 1: Isothermal atmosphere
! 2: Guillot 2010 radiative equilibrium profile
! 3: Dry adiabat initialisation
      real    :: ts = 300.       ! Surface temperature
      real    :: T_strat = 200.  ! Minimum stratospheric temperature. If init_type = 1, this is
! the atmospheric temperature
!
! Required for pressure level setup
      real :: surface_pressure
!
! Required for Guillot 2010 Initialisation
      real  :: S = 1360.       ! Stellar constant
      real  :: f = 1./4.       ! Flux redistribution constant (1/2 = dayside, 1/4 = global redist.)
      real  :: tau_sw, tau_lw  ! Total SW and LW fluxes for the atmosphere  
      real  :: Tint            ! Internal temperature

! Required for tp_file setup
      character(len=200) :: tp_file
      
contains

!-------------------------------------------------------------------------------
 subroutine p_var(km, ifirst, ilast, jfirst, jlast, ptop, ptop_min,    &
                  delp, delz, pt, ps,  pe, peln, pk, pkz, cappa, q, ng, nq, area,   &
                  dry_mass, adjust_dry_mass, mountain, moist_phys,      &
                  hydrostatic, nwat, domain, adiabatic, make_nh)

! Given (ptop, delp) computes (ps, pk, pe, peln, pkz)
! Input:
   integer,  intent(in):: km
   integer,  intent(in):: ifirst, ilast            ! Longitude strip
   integer,  intent(in):: jfirst, jlast            ! Latitude strip
   integer,  intent(in):: nq, nwat
   integer,  intent(in):: ng
   logical, intent(in):: adjust_dry_mass, mountain, moist_phys, hydrostatic, adiabatic
   real, intent(in):: dry_mass, cappa, ptop, ptop_min
   real, intent(in   )::   pt(ifirst-ng:ilast+ng,jfirst-ng:jlast+ng, km)
   real, intent(inout):: delz(ifirst:ilast,jfirst:jlast, km)
   real, intent(inout):: delp(ifirst-ng:ilast+ng,jfirst-ng:jlast+ng, km)
   real, intent(inout)::    q(ifirst-ng:ilast+ng,jfirst-ng:jlast+ng, km, nq)
   real(kind=R_GRID), intent(IN)   :: area(ifirst-ng:ilast+ng,jfirst-ng:jlast+ng)
   logical, optional:: make_nh
! Output:
   real, intent(out) ::   ps(ifirst-ng:ilast+ng, jfirst-ng:jlast+ng)
   real, intent(out) ::   pk(ifirst:ilast, jfirst:jlast, km+1)
   real, intent(out) ::   pe(ifirst-1:ilast+1,km+1,jfirst-1:jlast+1) ! Ghosted Edge pressure
   real, intent(out) :: peln(ifirst:ilast, km+1, jfirst:jlast)    ! Edge pressure
   real, intent(out) ::  pkz(ifirst:ilast, jfirst:jlast, km)
   type(domain2d), intent(IN) :: domain

! Local
   integer  sphum, liq_wat, ice_wat
   integer  rainwat, snowwat, graupel          ! GFDL Cloud Microphysics
   real ratio(ifirst:ilast)
   real pek, lnp, ak1, rdg, dpd, zvir
   integer i, j, k

! Check dry air mass & compute the adjustment amount:
   if ( adjust_dry_mass )      &
   call drymadj(km, ifirst, ilast,  jfirst,  jlast, ng, cappa, ptop, ps, &
                delp, q, nq, area, nwat, dry_mass, adjust_dry_mass, moist_phys, dpd, domain)

   pek = ptop ** cappa

!$OMP parallel do default(none) shared(ifirst,ilast,jfirst,jlast,km,ptop,pek,pe,pk, &
!$OMP                                  ps,adjust_dry_mass,dpd,delp,peln,cappa,      &
!$OMP                                  ptop_min,hydrostatic,pkz )                   &
!$OMP                          private(ratio, ak1, lnp)
   do j=jfirst,jlast
      do i=ifirst,ilast
         pe(i,1,j) = ptop
         pk(i,j,1) = pek
      enddo

      if ( adjust_dry_mass ) then
         do i=ifirst,ilast
            ratio(i) = 1. + dpd/(ps(i,j)-ptop)
         enddo
         do k=1,km
            do i=ifirst,ilast
               delp(i,j,k) = delp(i,j,k) * ratio(i)
            enddo
         enddo
      endif

      do k=2,km+1
         do i=ifirst,ilast
            pe(i,k,j) = pe(i,k-1,j) + delp(i,j,k-1)
            peln(i,k,j) = log(pe(i,k,j))
            pk(i,j,k) = exp( cappa*peln(i,k,j) )
         enddo
      enddo

      do i=ifirst,ilast
         ps(i,j) = pe(i,km+1,j)
      enddo

      if( ptop < ptop_min ) then
!---- small ptop modification -------------
          ak1 = (cappa + 1.) / cappa
          do i=ifirst,ilast
             peln(i,1,j) = peln(i,2,j) - ak1
          enddo
      else
             lnp = log( ptop )
          do i=ifirst,ilast
             peln(i,1,j) = lnp
          enddo
      endif

      if ( hydrostatic ) then
         do k=1,km
            do i=ifirst,ilast
               pkz(i,j,k) = (pk(i,j,k+1)-pk(i,j,k))/(cappa*(peln(i,k+1,j)-peln(i,k,j)))
            enddo
         enddo
      endif
   enddo

   if ( adiabatic  ) then
      zvir = 0.
   else
      zvir = rvgas/rdgas - 1.
   endif
   sphum   = get_tracer_index (MODEL_ATMOS, 'sphum')

   if ( .not.hydrostatic ) then

      rdg = -rdgas / grav
      if ( present(make_nh) ) then
          if ( make_nh ) then
             delz = 1.e25
!$OMP parallel do default(none) shared(ifirst,ilast,jfirst,jlast,km,delz,rdg,pt,peln,zvir,sphum,q)
             do k=1,km
                do j=jfirst,jlast
                   do i=ifirst,ilast
                      delz(i,j,k) = rdg*pt(i,j,k)*(1.+zvir*q(i,j,k,sphum))*(peln(i,k+1,j)-peln(i,k,j))
                   enddo
                enddo
             enddo
             if(is_master()) write(*,*) 'delz computed from hydrostatic state'
          endif
      endif

     if ( moist_phys ) then
!------------------------------------------------------------------
! The following form is the same as in "fv_update_phys.F90"
!------------------------------------------------------------------
!$OMP parallel do default(none) shared(ifirst,ilast,jfirst,jlast,km,pkz,cappa,rdg, &
!$OMP                                  delp,pt,zvir,q,sphum,delz)
       do k=1,km
          do j=jfirst,jlast
             do i=ifirst,ilast
                pkz(i,j,k) = exp( cappa*log(rdg*delp(i,j,k)*pt(i,j,k)*    &
                                (1.+zvir*q(i,j,k,sphum))/delz(i,j,k)) )
             enddo
          enddo
       enddo
     else
!$OMP parallel do default(none) shared(ifirst,ilast,jfirst,jlast,km,pkz,cappa,rdg, &
!$OMP                                  delp,pt,delz)
       do k=1,km
          do j=jfirst,jlast
             do i=ifirst,ilast
                pkz(i,j,k) = exp( cappa*log(rdg*delp(i,j,k)*pt(i,j,k)/delz(i,j,k)) )
             enddo
          enddo
       enddo
     endif

   endif

 end subroutine p_var



 subroutine drymadj(km,  ifirst, ilast, jfirst,  jlast,  ng, &
                    cappa,   ptop, ps, delp, q,  nq, area,  nwat,  &
                    dry_mass, adjust_dry_mass, moist_phys, dpd, domain)

! !INPUT PARAMETERS:
      integer km
      integer ifirst, ilast  ! Long strip
      integer jfirst, jlast  ! Latitude strip
      integer nq, ng, nwat
      real, intent(in):: dry_mass
      real, intent(in):: ptop
      real, intent(in):: cappa
      logical, intent(in):: adjust_dry_mass
      logical, intent(in):: moist_phys
      real(kind=R_GRID), intent(IN) :: area(ifirst-ng:ilast+ng, jfirst-ng:jlast+ng)
      type(domain2d), intent(IN) :: domain

! !INPUT/OUTPUT PARAMETERS:
      real, intent(in)::   q(ifirst-ng:ilast+ng,jfirst-ng:jlast+ng,km,nq)
      real, intent(in)::delp(ifirst-ng:ilast+ng,jfirst-ng:jlast+ng,km)     !
      real, intent(inout):: ps(ifirst-ng:ilast+ng,jfirst-ng:jlast+ng)        ! surface pressure
      real, intent(out):: dpd
! Local
      real  psd(ifirst:ilast,jfirst:jlast)     ! surface pressure  due to dry air mass
      real  psmo, psdry
      integer i, j, k

!$OMP parallel do default(none) shared(ifirst,ilast,jfirst,jlast,km,ps,ptop,psd,delp,nwat,q)
      do j=jfirst,jlast

         do i=ifirst,ilast
             ps(i,j) = ptop
            psd(i,j) = ptop
         enddo

         do k=1,km
            do i=ifirst,ilast
               ps(i,j) = ps(i,j) + delp(i,j,k)
            enddo
         enddo

       if ( nwat>=1 ) then
          do k=1,km
             do i=ifirst,ilast
                psd(i,j) = psd(i,j) + delp(i,j,k)*(1. - sum(q(i,j,k,1:nwat)))
             enddo
          enddo
        else
          do i=ifirst,ilast
             psd(i,j) = ps(i,j)
          enddo
        endif
      enddo

! Check global maximum/minimum
#ifndef QUICK_SUM
      psdry = g_sum(domain, psd, ifirst, ilast, jfirst, jlast, ng, area, 1, .true.)
       psmo = g_sum(domain, ps(ifirst:ilast,jfirst:jlast), ifirst, ilast, jfirst, jlast,  &
                     ng, area, 1, .true.)
#else
      psdry = g_sum(domain, psd, ifirst, ilast, jfirst, jlast, ng, area, 1)
       psmo = g_sum(domain, ps(ifirst:ilast,jfirst:jlast), ifirst, ilast, jfirst, jlast,  &
                     ng, area, 1)
#endif

      if(is_master()) then
         write(*,*) 'Total surface pressure (mb) = ', 0.01*psmo
         if ( moist_phys ) then
              write(*,*) 'mean dry surface pressure = ', 0.01*psdry
              write(*,*) 'Total Water (kg/m**2) =', real(psmo-psdry,4)/GRAV
         endif
      endif

      if( adjust_dry_mass ) Then
          dpd = real(dry_mass - psdry,4)
          if(is_master()) write(*,*) 'dry mass to be added (pascals) =', dpd
      endif

 end subroutine drymadj



 subroutine hydro_eq(km, is, ie, js, je, ps, hs, drym, delp, ak, bk,  &
                     pt, tsurf, delz, area, ng, mountain, hydrostatic, hybrid_z, domain, agrid)
! Input:
  integer, intent(in):: is, ie, js, je, km, ng
  real, intent(in):: ak(km+1), bk(km+1)
  real, intent(in):: hs(is-ng:ie+ng,js-ng:je+ng)
  real, intent(in):: drym
  logical, intent(in):: mountain
  logical, intent(in):: hydrostatic
  logical, intent(in):: hybrid_z
  real(kind=R_GRID), intent(IN) :: area(is-ng:ie+ng,js-ng:je+ng)
  type(domain2d), intent(IN) :: domain
  real, intent(in) :: agrid(is-ng:ie+ng,js-ng:je+ng, 2)
! Output
  real, intent(out):: ps(is-ng:ie+ng,js-ng:je+ng)
  real, intent(out)::   pt(is-ng:ie+ng,js-ng:je+ng,km)
  real, intent(out) :: tsurf(is:ie, js:je)
  real, intent(out):: delp(is-ng:ie+ng,js-ng:je+ng,km)
  real, intent(inout):: delz(is:,js:,1:)
! Local
  real   gz(is:ie,km+1)
  real   ph(is:ie,km+1)
  real mslp, z1, t1, p1, t0, a0, psm
  real ztop, c0
#ifdef INIT_4BYTE
  real(kind=4) ::  dps
#else
  real dps    ! note that different PEs will get differt dps during initialization
              ! this has no effect after cold start
#endif
  real p0, gztop, ptop, pf(km)
  integer  i,j,k, f_unit, unit, ios, exists, ierr
  logical master
  character(80) :: filename

! HI Added following:
  read(input_nml_file, initialisation_nml, iostat=ios)
  ierr=check_nml_error(ios, 'initialisation_nml')
  unit = stdlog()
  write(unit, nml=initialisation_nml)
  

  if ( is_master() ) write(*,*) 'Initializing ATM hydrostatically'

  if ( is_master() ) write(*,*) 'Initializing Earth'
! Given p1 and z1 (250mb, 10km)
        p1 = 25000.
        z1 = 10.E3 * grav
        t1 = 200.
        t0 = 300.            ! sea-level temp.
        a0 = (t1-t0)/z1*0.5
        c0 = t0/a0

     if ( hybrid_z ) then
          ptop = 100.   ! *** hardwired model top ***
     else
          ptop = ak(1)
     endif

     ztop = z1 + (rdgas*t1)*log(p1/ptop)
     if(is_master()) write(*,*) 'ZTOP is computed as', ztop/grav*1.E-3

  if ( mountain ) then
     mslp = 100917.4
     do j=js,je
        do i=is,ie
           !ps(i,j) = mslp*( c0/(hs(i,j)+c0))**(1./(a0*rdgas))
           ps(i,j) = mslp*exp(-1./(a0*rdgas)*hs(i,j)/(hs(i,j)+c0))
        enddo
     enddo
     psm = g_sum(domain, ps(is:ie,js:je), is, ie, js, je, ng, area, 1, .true.)
     dps = drym - psm
     if(is_master()) write(*,*) 'Computed mean ps=', psm
     if(is_master()) write(*,*) 'Correction delta-ps=', dps
  else
     mslp = drym  ! 1000.E2
     do j=js,je
        do i=is,ie
           ps(i,j) = surface_pressure
        enddo
     enddo
     dps = 0.
  endif


  do j=js,je
     do i=is,ie
        ps(i,j) = ps(i,j) + dps
        gz(i,   1) = ztop
        gz(i,km+1) = hs(i,j)
        ph(i,   1) = ptop
        ph(i,km+1) = ps(i,j)
     enddo

     if ( hybrid_z ) then
!---------------
! Hybrid Z
!---------------
        do k=km,2,-1
           do i=is,ie
              gz(i,k) = gz(i,k+1) - delz(i,j,k)*grav
           enddo
        enddo
! Correct delz at the top:
        do i=is,ie
            delz(i,j,1) = (gz(i,2) - ztop) / grav
        enddo

        do k=2,km
           do i=is,ie
              if ( gz(i,k) >= z1 ) then
! Isothermal
                 ph(i,k) = ptop*exp( (gz(i,1)-gz(i,k))/(rdgas*t1) )
              else
! Constant lapse rate region (troposphere)
                 !ph(i,k) = ps(i,j)*((hs(i,j)+c0)/(gz(i,k)+c0))**(1./(a0*rdgas))
                 ph(i,k) = ps(i,j)*exp(-1./(a0*rdgas)*(gz(i,k)-hs(i,j))/(gz(i,k)-hs(i,j)+c0))
              endif
           enddo
        enddo
     else
!---------------
! Hybrid sigma-p
!---------------
       do k=2,km+1
          do i=is,ie
             ph(i,k) = ak(k) + bk(k)*ps(i,j)
          enddo
       enddo

       do k=km,2,-1
          do i=is,ie
             if (ph(i,k) <= p1) then
                gz(i,k) = gz(i,k+1) +  (rdgas*t1)*log(ph(i,k+1)/ph(i,k))
             else
! Constant lapse rate region (troposphere)
                 !gz(i,k) = (hs(i,j)+c0)/(ph(i,k)/ps(i,j))**(a0*rdgas) - c0
                 gz(i,k) = c0/(1+a0*rdgas*log(ph(i,k)/ps(i,j)))+hs(i,j)-c0
             endif
          enddo
       enddo
       !model top
          do i=is,ie
             if (ph(i,1) <= p1) then
                gz(i,1) = gz(i,2) +  (rdgas*t1)*log(ph(i,2)/ph(i,1))
             else
                gz(i,1) = (hs(i,j)+c0)/(ph(i,1)/ps(i,j))**(a0*rdgas) - c0
             endif
          enddo
       if ( .not. hydrostatic ) then
          do k=1,km
             do i=is,ie
                delz(i,j,k) = ( gz(i,k+1) - gz(i,k) ) / grav
             enddo
          enddo
       endif
     endif  ! end hybrid_z

! Convert geopotential to Temperature
      do k=1,km
         do i=is,ie
              pt(i,j,k) = (gz(i,k)-gz(i,k+1))/(rdgas*(log(ph(i,k+1)/ph(i,k))))
              pt(i,j,k) = max(t1, pt(i,j,k))
              delp(i,j,k) = ph(i,k+1) - ph(i,k)
           enddo
           pf(k) = (ph(is,k+1) - ph(is,k))/(log(ph(is,k+1)) - log(ph(is,k)))
      enddo
   enddo    ! j-loop

   ! HI added:
   call tp_init(is-ng, ie+ng, js-ng, je+ng, ng, km, pf, pt, agrid)
   
   do j=js,je
      do i=is,ie
         tsurf(i,j) = pt(i,j,km)
      enddo
   enddo
   ! End HI added

 end subroutine hydro_eq


 ! Added by Linjiong Zhou, bugfix + increase temperature above tropospause
 subroutine hydro_eq_ext(km, is, ie, js, je, ps, hs, drym, delp, ak, bk,  &
                     pt, delz, area, ng, mountain, hydrostatic, hybrid_z, domain)
! Input:
  integer, intent(in):: is, ie, js, je, km, ng
  real, intent(in):: ak(km+1), bk(km+1)
  real, intent(in):: hs(is-ng:ie+ng,js-ng:je+ng)
  real, intent(in):: drym
  logical, intent(in):: mountain
  logical, intent(in):: hydrostatic
  logical, intent(in):: hybrid_z
  real(kind=R_GRID), intent(IN) :: area(is-ng:ie+ng,js-ng:je+ng)
  type(domain2d), intent(IN) :: domain
! Output
  real, intent(out):: ps(is-ng:ie+ng,js-ng:je+ng)
  real, intent(out)::   pt(is-ng:ie+ng,js-ng:je+ng,km)
  real, intent(out):: delp(is-ng:ie+ng,js-ng:je+ng,km)
  real, intent(inout):: delz(is:,js:,1:)
! Local
  real   gz(is:ie,km+1)
  real   ph(is:ie,km+1)
  real mslp, z1, z2, t1, t2, p1, p2, t0, a0, a1, psm
  real ztop, c0, c1
#ifdef INIT_4BYTE
  real(kind=4) ::  dps
#else
  real dps    ! note that different PEs will get differt dps during initialization
              ! this has no effect after cold start
#endif
  real p0, gztop, ptop
  integer  i,j,k

  if ( is_master() ) write(*,*) 'Initializing ATM hydrostatically'

  if ( is_master() ) write(*,*) 'Initializing Earth'
! Given p1 and z1 (100mb, 15km)
! Given p2 and z2 (1mb, 45km)
        p2 = 1.e2
        p1 = 100.e2
        z2 = 45.E3 * grav
        z1 = 15.E3 * grav
        t2 = 260.
        t1 = 200.
        t0 = 300.            ! sea-level temp.
        a0 = (t1-t0)/z1*0.5
        a1 = (t2-t1)/(z2-z1)*0.5
        c0 = t0/a0
        c1 = t1/a1

     if ( hybrid_z ) then
          ptop = 100.   ! *** hardwired model top ***
     else
          ptop = ak(1)
     endif

     ztop = z2 + (rdgas*t2)*log(p2/ptop)
     if(is_master()) write(*,*) 'ZTOP is computed as', ztop/grav*1.E-3

  if ( mountain ) then
     mslp = 100917.4
     do j=js,je
        do i=is,ie
           !ps(i,j) = mslp*( c0/(hs(i,j)+c0))**(1./(a0*rdgas))
           ps(i,j) = mslp*exp(-1./(a0*rdgas)*hs(i,j)/(hs(i,j)+c0))
        enddo
     enddo
     psm = g_sum(domain, ps(is:ie,js:je), is, ie, js, je, ng, area, 1, .true.)
     dps = drym - psm
     if(is_master()) write(*,*) 'Computed mean ps=', psm
     if(is_master()) write(*,*) 'Correction delta-ps=', dps
  else
     mslp = drym  ! 1000.E2
     do j=js,je
        do i=is,ie
           ps(i,j)  = surface_pressure
        enddo
     enddo
     dps = 0.
  endif


  do j=js,je
     do i=is,ie
        ps(i,j) = ps(i,j) + dps
        gz(i,   1) = ztop
        gz(i,km+1) = hs(i,j)
        ph(i,   1) = ptop
        ph(i,km+1) = ps(i,j)
     enddo

     if ( hybrid_z ) then
!---------------
! Hybrid Z
!---------------
        do k=km,2,-1
           do i=is,ie
              gz(i,k) = gz(i,k+1) - delz(i,j,k)*grav
           enddo
        enddo
! Correct delz at the top:
        do i=is,ie
            delz(i,j,1) = (gz(i,2) - ztop) / grav
        enddo

        do k=2,km
           do i=is,ie
              if ( gz(i,k) >= z2 ) then
! Isothermal
                 ph(i,k) = ptop*exp( (gz(i,1)-gz(i,k))/(rdgas*t2) )
              else if ( gz(i,k) >= z1 ) then
! Constant lapse rate region (troposphere)
                 !ph(i,k) = p1*((z1+c1)/(gz(i,k)+c1))**(1./(a1*rdgas))
                 ph(i,k) = p1*exp(-1./(a1*rdgas)*(gz(i,k)-z1)/(gz(i,k)-z1+c1))
              else
! Constant lapse rate region (troposphere)
                 !ph(i,k) = ps(i,j)*((hs(i,j)+c0)/(gz(i,k)+c0))**(1./(a0*rdgas))
                 ph(i,k) = ps(i,j)*exp(-1./(a0*rdgas)*(gz(i,k)-hs(i,j))/(gz(i,k)-hs(i,j)+c0))
              endif
           enddo
        enddo
     else
!---------------
! Hybrid sigma-p
!---------------
       do k=2,km+1
          do i=is,ie
             ph(i,k) = ak(k) + bk(k)*ps(i,j)
          enddo
       enddo

       do k=2,km
          do i=is,ie
             if ( ph(i,k) <= p2 ) then
! Isothermal
                 gz(i,k) = ztop + (rdgas*t2)*log(ptop/ph(i,k))
             else if ( ph(i,k) <= p1 ) then
! Constant lapse rate region (troposphere)
                 !gz(i,k) = (z1+c1)/(ph(i,k)/p1)**(a1*rdgas) - c1
                 gz(i,k) = c1/(1+a1*rdgas*log(ph(i,k)/p1))+z1-c1
             else
! Constant lapse rate region (troposphere)
                 !gz(i,k) = (hs(i,j)+c0)/(ph(i,k)/ps(i,j))**(a0*rdgas) - c0
                 gz(i,k) = c0/(1+a0*rdgas*log(ph(i,k)/ps(i,j)))+hs(i,j)-c0
             endif
          enddo
       enddo
       if ( .not. hydrostatic ) then
          do k=1,km
             do i=is,ie
                delz(i,j,k) = ( gz(i,k+1) - gz(i,k) ) / grav
             enddo
          enddo
       endif
     endif  ! end hybrid_z

! Convert geopotential to Temperature
      do k=1,km
         do i=is,ie
              pt(i,j,k) = (gz(i,k)-gz(i,k+1))/(rdgas*(log(ph(i,k+1)/ph(i,k))))
              pt(i,j,k) = max(t1, pt(i,j,k))
            delp(i,j,k) = ph(i,k+1) - ph(i,k)
         enddo
      enddo
   enddo    ! j-loop


 end subroutine hydro_eq_ext

 subroutine tp_init(is, ie, js, je, ng, num_levels, pf, Tf, agrid)
    !---------------------------------------------------------------------------------------
    ! Purpose: Initialising temperature grid at beginning of run                          
    ! --------------------------------------------------------------------------------------

    !---------------------------------------------------------------------------------------
    ! Input arguments
    !---------------------------------------------------------------------------------------
    integer, intent(in) :: is,ie,js,je,ng,num_levels
    real,    intent(in) :: pf(num_levels)
    real, intent(in) :: agrid(is-ng:ie+ng,js-ng:je+ng, 2)
    !---------------------------------------------------------------------------------------
    ! Output arguments
    !---------------------------------------------------------------------------------------
    real, intent(out) :: Tf(is:ie, js:je, num_levels)


    !---------------------------------------------------------------------------------------
    ! Local arguments
    !---------------------------------------------------------------------------------------
    
    integer :: i,j,k
    logical :: master
    character(80) :: filename

    ! Required for Guillot 2010 setup
    real, dimension(num_levels) :: tau ! Optical depth = tau_lw*(p/ps)
    real  :: gamma, mu, lat_tl 
    real  :: Tirr ! Irradiation temperature
    
    !---------------------------------------------------------------------------------------
    ! Main body of function
    !---------------------------------------------------------------------------------------

! Select type of initialisation profile
    select case(init_type)

! Isothermal profile
    case(1)
       Tf(is:ie,js:je,1:num_levels) = T_strat

! Guillot 2010, equation 29
    case(2)
       Tirr = (S/stefan)**0.25
       tau = pf /surface_pressure * tau_lw!pf/surface_pressure * tau_lw
       gamma = tau_sw/tau_lw
       !gamma = tau_sw/tau_lw

       do k=1,num_levels
          Tf(is:ie,js:je,k) = ( 3./4.*Tint**4.*(2./3. + tau(k)) + &
               3./4.*Tirr**4*f*(2./3. + 1./gamma/sqrt(3.) + &
               (gamma/sqrt(3.) - 1./gamma/sqrt(3.))*exp(-gamma*tau(k)*sqrt(3.)) ) ) ** (0.25)
       enddo

!       if (is_master() ) then
!          write(*,*) 'testing'
!          write(*,*) 'tau', tau
!          write(*,*) 'num_levels', num_levels
!          write(*,*) 'gamma', gamma
!          write(*,*)  'T_int', T_int
!          write(*,*) 'sp', sp
!          write(*,*) maxval(Tf(is:ie,js:je,1:num_levels)),minval(Tf(is:ie,js:je,1:num_levels))
!       endif
       
! Dry adiabat
    case(3)
       do k=1, num_levels
          do j=js,je
             do i=is,ie
                Tf(i,j,k) = ts* (pf(k)/pf(num_levels)) ** kappa
                Tf(i,j,k) = max(Tf(i,j,k), T_strat)
             end do
          end do
       end do

! Guillot 2010, equation 27, + Koll 2015 equation B3
    case(4)
       Tirr = (S/stefan)**0.25
       tau = pf/surface_pressure * tau_lw
       gamma = tau_sw/tau_lw
       do i=is,ie
          do j=js,je
             lat_tl = asin(cos(agrid(i,j,2))*cos(agrid(i,j,1)))
             mu = cos(lat_tl)
             do k=1,num_levels
                Tf(i,j,k) = ( 3./4.*Tint**4.*(2./3. + tau(k)) + &
                     3./4.*Tirr**4*mu*(2./3. + mu/gamma + &
                     ((gamma/(3*mu)) - (mu/gamma)) * exp( -gamma*tau(k)/mu) ) )** (0.25)
             enddo
          enddo
       enddo

! Init from profile
    case(5)
       call read_tp_from_nc(is,ie,js,je,num_levels,pf,Tf)
    end select

    if (is_master()) then
       write(*,*) 'Initialised TP'
       write(*,*) 'Pressure (Pa), Temperature (K)'
       do k=1,num_levels
          write(*,*) pf(k), minval(Tf(is:ie,js:je,k)), maxval(Tf(is:ie,js:je,k))
       enddo
    endif
  end subroutine tp_init

  subroutine read_tp_from_nc(is,ie,js,je,npz,p,T)
    integer, intent(in)              :: is,ie,js,je,npz
    real, dimension(npz), intent(in)  :: p
    real, dimension(is:ie,js:je,npz), intent(out) :: T
    real, allocatable :: p_dat(:), T_dat(:)
    
    integer :: ierr, ncid, idv_t, idv_p, idd_p, ndat, k
    integer :: i,j,m(1),z

    ierr = nf90_open(trim(tp_file), 0, ncid)
    call handle_err(ierr)

    ! Pressure dimension (get length)
    ierr = nf90_inq_dimid(ncid, "pfull", idd_p)
    call handle_err(ierr)
    ierr = nf90_inquire_dimension(ncid, idd_p, len=ndat)
    call handle_err(ierr)

    allocate(p_dat(ndat), T_dat(ndat))

    ! Variables
    ierr = nf90_inq_varid(ncid, "pfull", idv_p)
    call handle_err(ierr)
    ierr = nf90_inq_varid(ncid, "Tf", idv_t)
    call handle_err(ierr)
    ierr = nf90_get_var(ncid, idv_p, p_dat)
    call handle_err(ierr)
    ierr = nf90_get_var(ncid, idv_t, T_dat)
    call handle_err(ierr)

! Interpolate values - note default is to extrapolate at both bottom and top if pressure
! is not in the range of data provided
    
    do k=1,npz
       m = minloc(abs(p_dat - p(k)))
       z = m(1)
       if (p(k) .lt. p_dat(z) .and. z .ne. 1) z = z-1
       if (z .eq. ndat) z = z-1

       call linear_log_interp(p(k), p_dat(z), p_dat(z+1), T_dat(z), T_dat(z+1), T(is,js,k))

       do j=js,je
          do i=is,ie
             T(i,j,k) = T(is,js,k)
          enddo
       enddo
    enddo
    
    
  end subroutine read_tp_from_nc

  subroutine handle_err(status)
    integer, intent(in) :: status

    if (status /= nf90_noerr) then
       write(*,*) trim(nf90_strerror(status))
       stop "Stopped" 
    endif
  end subroutine handle_err
  
end module init_hydro_mod
