import { ComponentFixture, TestBed } from '@angular/core/testing';
import { UiDesignSystem } from './ui-design-system';

describe('UiDesignSystem', () => {
  let component: UiDesignSystem;
  let fixture: ComponentFixture<UiDesignSystem>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [UiDesignSystem],
    }).compileComponents();

    fixture = TestBed.createComponent(UiDesignSystem);
    component = fixture.componentInstance;
    await fixture.whenStable();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
